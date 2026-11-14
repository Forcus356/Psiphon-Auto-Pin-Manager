#!/usr/bin/env python3
"""Unauthenticated Gemini availability probe. Exit 0 served, 1 refused, 2 inconclusive."""
import argparse
import http.cookiejar
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
from urllib.parse import urlencode, urlsplit

APP='https://gemini.google.com/app'
ENDPOINT='https://gemini.google.com/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate'

def curl(args, timeout=90, executable="curl"):
    try:
        p=subprocess.run([executable,'-4','-sS','--max-time',str(timeout),*args],
                         capture_output=True, text=True, timeout=timeout+5)
        return p.returncode,p.stdout,p.stderr
    except (OSError,subprocess.TimeoutExpired) as e:
        return 1,'',str(e)

def model_request(common,request,url,folder):
    """Keep the HTTP/2 connection active while the anonymous model generates a reply."""
    result=Path(folder)/'reply'
    headers=['-H','Content-Type: application/x-www-form-urlencoded;charset=utf-8',
             '-H','Origin: https://gemini.google.com','-H','Referer: https://gemini.google.com/']
    marker='autopin-model-done'
    args=['curl','--parallel','-4','-sS',*common,*headers,'--max-time','130',
          '-o',str(result),'-w','%{stderr}'+marker,'--data-urlencode',request,url,
          '--next','-4','-sS',*common,*headers,'--max-time','130','-X','POST','-T','-',
          '-o','/dev/null',ENDPOINT+'?rt=c']
    done=threading.Event()
    try:
        process=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    except OSError as exc:return 1,'',str(exc)
    def feed():
        while not done.is_set():
            try:process.stdin.write(b'x');process.stdin.flush()
            except (OSError,ValueError):break
            if done.wait(2):break
        try:process.stdin.close()
        except (OSError,ValueError):pass
    def observe():
        tail=b''
        while True:
            char=process.stderr.read(1)
            if not char:break
            tail=(tail+char)[-len(marker):]
            if tail==marker.encode():done.set()
    writer=threading.Thread(target=feed,daemon=True);reader=threading.Thread(target=observe,daemon=True)
    writer.start();reader.start()
    try:
        code=process.wait(timeout=140)
    except subprocess.TimeoutExpired:
        process.kill();process.wait();code=1
    finally:
        done.set();writer.join(timeout=3);reader.join(timeout=3)
        process.stderr.close()
    return code,result.read_text(errors='replace') if result.exists() else '', ''

def check(port, impersonate_dir=None, host="127.0.0.1"):
    proxy=f'socks5h://{host}:{port}'
    with tempfile.TemporaryDirectory(prefix='gemini-check-') as tmp:
        jar=str(Path(tmp)/'cookies')
        common=['--noproxy','','--proxy',proxy,'-A','Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36',
                '-H','Accept-Language: en-US,en;q=0.9','-b',jar,'-c',jar]
        page_binary='curl'
        if impersonate_dir:
            profiles=[p for p in Path(impersonate_dir).glob('curl_chrome*') if re.fullmatch(r'curl_chrome[0-9]+',p.name)]
            if not profiles:return 'INCONCLUSIVE','browser TLS profile missing'
            page_binary=str(max(profiles,key=lambda p:int(p.name.removeprefix('curl_chrome'))))
        page_common=common if not impersonate_dir else ['--noproxy','','--proxy',proxy,'-b',jar,'-c',jar]
        headers=Path(tmp)/'headers'
        rc,page,err=curl([*page_common,'-D',str(headers),APP],timeout=30,executable=page_binary)
        if impersonate_dir and headers.exists():
            for line in headers.read_text(errors='replace').splitlines():
                if line.lower().startswith('location:'):
                    u=urlsplit(line.split(':',1)[1].strip())
                    if re.fullmatch(r'(?:[a-z0-9-]+\.)*google\.[a-z.]+',u.hostname or '') and u.path.startswith('/sorry'):
                        return 'CAPTCHA','browser TLS request redirected to Google CAPTCHA'
        if rc:return 'INCONCLUSIVE',f'page fetch failed: {err[-120:]}'
        # Fields are from the public, unauthenticated application page.
        bl=re.search(r'"cfb2h":"([^"\\]+)"',page)
        sid=re.search(r'"FdrFJe":"([^"\\]+)"',page)
        if not bl or not sid:return 'INCONCLUSIVE','session fields absent; Google page may have changed'
        query=urlencode({'bl':bl.group(1),'f.sid':sid.group(1),'hl':'en','_reqid':'100000','rt':'c'})
        req='f.req=[null,"[[\\"hi\\"],null,null]"]'
        rc,out,err=model_request(common,req,ENDPOINT+'?'+query,tmp)
        if rc:return 'INCONCLUSIVE',f'request failed: {err[-120:]}'
        if re.search(r'BardErrorInfo\\?\",\\?\[1060(?:\D|$)',out):return 'REFUSED','Gemini error 1060'
        # Do not count a 200 HTML page, captcha or generic response as a successful model reply.
        if re.search(r'SWML_DESCRIPTION',out) and 'wrb.fr' in out:
            return 'SERVING','anonymous model reply detected'
        return 'INCONCLUSIVE','no explicit Gemini verdict'

if __name__=='__main__':
    ap=argparse.ArgumentParser()
    ap.add_argument('--port',type=int,required=True)
    ap.add_argument('--impersonate-dir')
    ap.add_argument('--host',default='127.0.0.1')
    a=ap.parse_args()
    if not 1024<=a.port<=65534:ap.error('invalid port')
    verdict,reason=check(a.port,a.impersonate_dir,a.host)
    print(f'{verdict}: {reason}',flush=True)
    sys.exit({'SERVING':0,'REFUSED':1,'INCONCLUSIVE':2,'CAPTCHA':3}[verdict])
