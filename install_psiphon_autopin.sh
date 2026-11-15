#!/usr/bin/env bash
# Forcus Psiphon Auto-Pin Manager v4.4.0
# Author: https://github.com/Forcus356
# Ubuntu/Debian x86_64
autopin_install_main() {
set -Eeuo pipefail
umask 077
PIN_IMAGE='swarupsengupta2007/psiphon@sha256:ed678abc7145e0fb550eb889a5dfed74bd8495bca16b958d6b7ac582d869bfe6'
CONSOLE_COMMIT='c49818e8b2fe7b64657aea27b53f12d1374d21eb'
CONSOLE_SHA256='faf6873ddc1dab6c00e11a090a711fb3a26cfa7dbc1717e0c3b1978dfff4c105'
CONSOLE_BASE='debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc'
autopin_return_to_menu() {
    [[ ${AUTOPIN_MENU_PARENT:-0} != 1 ]] || return 0
    if [[ ${MENU_REQUESTED:-0} != 1 && ! -t 1 ]]; then return 0; fi
    if ! ( : </dev/tty ) 2>/dev/null; then return 0; fi
    # Never carry the installation lock into a long-lived interactive menu.
    if [[ -n ${AUTOPIN_TRANSACTION_LOCK_FD:-} ]]; then
        flock -u "$AUTOPIN_TRANSACTION_LOCK_FD"
        exec {AUTOPIN_TRANSACTION_LOCK_FD}>&-
    fi
    echo '[INFO] Сервис запущен; это ещё не подтверждение найденного IP. Текущий результат показан в меню.'
    exec /usr/local/sbin/auto-pin --instance "$INSTANCE"
}
trap 'echo "[ERROR] Line $LINENO; journalctl -u psiphon-autopin -n 80 --no-pager" >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }
. /etc/os-release
[[ ${ID:-} == ubuntu || ${ID:-} == debian ]] || { echo 'Ubuntu/Debian only' >&2; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo 'x86_64 only' >&2; exit 1; }
# Interactive setup is opt-in for flag-based/automated invocations.
write_menu_module() {
cat <<'PY_MENU'
#!/usr/bin/env python3
"""Interactive setup for Forcus Auto-Pin. CLI flags remain the source of truth."""
import argparse
import base64
import hashlib
import urllib.request
import copy
import datetime as dt
from dataclasses import dataclass
from decimal import Decimal, DecimalException
import ipaddress
import json
import os
import re
import shutil
import socket
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unicodedata
import uuid

VERSION='4.4.0'
ROOT=Path('/')

@dataclass(frozen=True)
class Field:
    key: str
    label: str
    kind: str
    help: str
    low: int=0
    high: int=0
    choices: tuple=()

FIELDS=(
    Field('region','Страна Psiphon','region','Двухбуквенный код: NL, DE, PL, US. AUTO — любая доступная страна.'),
    Field('connection_type','Формат подключения','choice','Оба варианта используют SOCKS5 Psiphon. Xray — готовый outbound JSON.',choices=('socks5','xray')),
    Field('gemini_check','Проверять доступность Gemini','bool','Без Gemini продолжают работать проверки страны Google, скорости и восстановление.'),
    Field('port','SOCKS-порт на VPS','int','HTTP, если включён, использует следующий порт. Порт должен быть свободен.',1024,65534),
    Field('publish_http','Публиковать HTTP-прокси','bool','SOCKS5 работает независимо от публикации HTTP.'),
    Field('bind','Адрес привязки','bind','127.0.0.1 либо существующий частный IPv4 VPS. Для Xray в Docker bridge нужен доступный ему адрес хоста.'),
    Field('region_pool','Пул стран','countries','Например NL,DE,PL. Символ - очищает пул. При смене страны вне пула пул очищается.'),
    Field('tunnel_pool','Туннелей в экземпляре','int','1 — точечный PIN. 2–32 — несколько туннелей с выборочными проверками, без единого PIN.',1,32),
    Field('deny_regions','Запрещённые страны Google','countries','Например RU,BY. Символ - отключает список запрещённых стран.'),
    Field('strict_region','Требовать совпадения страны Google','bool','Google должен определять запрошенную страну. Страна Psiphon и оценка Google могут отличаться.'),
    Field('min_speed_kib','Минимальная скорость, KiB/s','int','0 отключает смену выхода по низкой скорости.',0,2147483647),
    Field('probe_mb','Объём пробы скорости, MiB','int','0–10. При 0 и включённом пороге скорости измеряется небольшая страница.',0,10),
    Field('slow_threshold','Низких измерений до смены выхода','int','Последовательные низкие измерения; успешное измерение сбрасывает счётчик.',2,20),
    Field('fail_threshold','Ошибок до восстановления','int','Сколько последовательных ошибок допускается перед восстановлением.',2,20),
    Field('interval','Watchdog / интервал проверок, мин','minutes','Период обычных проверок нашего монитора, минимум 1 минута. Например 1, 5, 10, 30; можно 1,5. После ошибок повторы выполняются чаще.',60,2147483647),
    Field('wait','Ожидание готовности туннеля, секунд','int','Минимум 20.',20,2147483647),
    Field('delay','Пауза между попытками поиска, секунд','int','Минимум 2.',2,2147483647),
    Field('impersonate','TLS-профиль браузера для Gemini','bool','Используется при проверке Gemini. Браузерный профиль загружается с проверкой SHA256.'),
    Field('backend','Вариант запуска','choice','auto сохраняет/определяет текущий вариант; новая установка использует vps-psiphon.',choices=('auto','vps-psiphon','console')),
    Field('youtube_mode','YouTube Mode','bool','Для YouTube ищется выход, который Google определяет как российский (RU). Чтобы запустить YouTube и Gemini вместе, выберите «Шаблоны» в главном меню.'),
)
EASY_KEYS=('region','connection_type','gemini_check','port','interval','youtube_mode')
TRUE={'1','y','yes','да','д','true','on'}
FALSE={'0','n','no','нет','н','false','off'}


def located(path):return ROOT/path.lstrip('/')
def paths(instance):
    suffix='' if instance==1 else '-'+str(instance)
    return {'app':located('/opt/psiphon-autopin'+suffix),
            'data':located('/var/lib/psiphon-autopin'+suffix),
            'manager':located('/opt/psiphon-autopin'+suffix+'/psiphon_autopin.py')}

def valid_instance(value):
    if isinstance(value,bool):raise ValueError('Номер экземпляра: 1–99')
    n=int(value)
    if not 1<=n<=99:raise ValueError('Номер экземпляра: 1–99')
    return n

def defaults(instance=1):
    return dict(instance=instance,region='NL',connection_type='socks5',gemini_check=True,
        port=40000+2*(instance-1),publish_http=True,bind='127.0.0.1',region_pool=[],tunnel_pool=1,
        deny_regions=['RU','BY','IR','SY','CU','KP','CN','VE'],strict_region=False,
        min_speed_kib=800,probe_mb=4,slow_threshold=2,fail_threshold=3,interval=300,
        wait=75,delay=12,impersonate=False,backend='auto',menu_mode='easy',youtube_mode=False)

def country_list(text):
    values=str(text).replace(',',' ').upper().split()
    if any(len(c)!=2 or not c.isascii() or not c.isalpha() for c in values):
        raise ValueError('Используйте двухбуквенные коды стран, например NL,DE')
    return list(dict.fromkeys(values))

def parse_field(field,text):
    text=text.strip()
    if field.kind=='minutes':
        try:value=Decimal(text.replace(',','.'))*60
        except DecimalException:raise ValueError('Введите интервал в минутах, например 5 или 1,5')
        if not value.is_finite() or not field.low<=value<=field.high or value!=value.to_integral_value():
            raise ValueError('Минимум 1 минута; интервал должен соответствовать целому числу секунд')
        return int(value)
    if field.kind=='int':
        value=int(text)
        if not field.low<=value<=field.high:raise ValueError(f'Допустимый диапазон: {field.low}–{field.high}')
        return value
    if field.kind=='bool':
        if text.lower() in TRUE:return True
        if text.lower() in FALSE:return False
        raise ValueError('Введите да или нет')
    if field.kind=='choice':
        if text.isdigit() and 1<=int(text)<=len(field.choices):return field.choices[int(text)-1]
        if text.lower() in field.choices:return text.lower()
        raise ValueError('Выберите: '+', '.join(field.choices))
    if field.kind=='countries':return [] if text=='-' else country_list(text)
    if field.kind=='region':
        if text.upper()=='AUTO':return ''
        values=country_list(text)
        if len(values)!=1:raise ValueError('Введите одну страну или AUTO; список стран задаётся в Advanced')
        return values[0]
    if field.kind=='bind':
        address=ipaddress.ip_address(text)
        if address.version!=4 or not any(address in ipaddress.ip_network(c) for c in ('127.0.0.0/8','10.0.0.0/8','172.16.0.0/12','192.168.0.0/16')):
            raise ValueError('Нужен loopback или частный IPv4; публичные адреса не разрешены')
        return str(address)
    raise ValueError('Неизвестный параметр')

def validate(config):
    valid_instance(config['instance'])
    for field in FIELDS:
        value=config[field.key]
        if field.kind=='bool':
            if type(value) is not bool:raise ValueError(field.label+': нужен boolean')
        elif field.kind in ('int','minutes'):
            if isinstance(value,bool) or int(value)!=value:raise ValueError(field.label+': нужно целое число')
            if field.kind=='minutes':
                if not field.low<=value<=field.high:raise ValueError('Минимум 1 минута')
            else:parse_field(field,str(int(value)))
        elif field.kind=='countries':
            if not isinstance(value,list):raise ValueError(field.label+': нужен список')
            country_list(' '.join(value))
        else:parse_field(field,'AUTO' if field.kind=='region' and value=='' else str(value))
    if config['youtube_mode']:
        if config['gemini_check']:raise ValueError('YouTube и Gemini требуют двух независимых экземпляров')
        if config['tunnel_pool']!=1:raise ValueError('YouTube Mode требует один туннель для проверяемого PIN')
        if not ipaddress.ip_address(config['bind']).is_loopback:raise ValueError('YouTube Mode требует loopback')
    if config.get('menu_mode') not in ('easy','advanced'):raise ValueError('Неизвестный режим меню')
    if config['region_pool'] and config['region'] not in config['region_pool']:
        raise ValueError('Текущая страна должна входить в пул стран; очистите пул или выберите страну из него')
    if config['backend']=='console' and config['bind']!='127.0.0.1':
        raise ValueError('Частный адрес требует backend vps-psiphon')
    return config

def load_config(instance):
    result=defaults(instance);path=paths(instance)['data']/'settings.json'
    if path.exists():
        saved=json.loads(path.read_text())
        if not isinstance(saved,dict):raise ValueError('settings.json должен содержать объект')
        for key in result:
            if key in saved and key!='instance':result[key]=copy.deepcopy(saved[key])
    validate(result)
    return result

def discover():
    found=[]
    for n in range(1,100):
        p=paths(n)
        if p['manager'].is_file() or (p['data']/'settings.json').is_file():found.append(n)
    return found

TEMPLATES={
    '1':('Gemini: да · YouTube: да',('gemini','youtube')),
    '2':('Gemini: да · YouTube: нет',('gemini',)),
    '3':('Gemini: нет · YouTube: да',('youtube',)),
}

def mode_label(config):
    return 'YouTube' if config['youtube_mode'] else 'Gemini' if config['gemini_check'] else 'Psiphon'

def instance_origin(number):
    try:
        value=json.loads((paths(number)['data']/'origin.json').read_text())
        if isinstance(value,dict) and value.get('source')=='template' and isinstance(value.get('group'),str):return value
    except (OSError,ValueError):pass
    return {}

def instance_label(number):
    try:config=load_config(number)
    except (ValueError,OSError,TypeError):return f'Экземпляр {number} — настройки недоступны'
    return f'Экземпляр {number} — {mode_label(config)}, SOCKS {config["port"]}'

def mark_template(numbers,group=None):
    group=group or uuid.uuid4().hex
    for number in numbers:
        config=load_config(number)
        atomic_json(paths(number)['data']/'origin.json',{'source':'template','group':group,
            'role':mode_label(config),'marked_at':dt.datetime.now(dt.timezone.utc).isoformat()})

def proxy_ports(config):
    return {config['port'],config['port']+1} if config['publish_http'] else {config['port']}

def ports_available(ports):
    sockets=[]
    try:
        for port in sorted(ports):
            sock=socket.socket();sockets.append(sock);sock.bind(('127.0.0.1',port))
        return True
    except OSError:return False
    finally:
        for sock in sockets:sock.close()

def template_plan(choice,preferred=1):
    """Prepare fresh instances only; never overwrite an existing policy."""
    installed=discover();used=set(installed);reserved=set()
    for number in installed:reserved.update(proxy_ports(load_config(number)))
    plan=[]
    for role in TEMPLATES[choice][1]:
        numbers=[preferred]+[n for n in range(1,100) if n!=preferred]
        number=next((n for n in numbers if n not in used),None)
        if number is None:raise ValueError('Нет свободного номера экземпляра (1–99)')
        port=next((n for n in range(40000,65534,2) if not {n,n+1}&reserved and ports_available({n,n+1})),None)
        if port is None:raise ValueError('Нет свободной пары SOCKS/HTTP-портов')
        config=defaults(number)
        config.update(youtube_mode=role=='youtube',gemini_check=role=='gemini',region='' if role=='youtube' else 'NL',
                      min_speed_kib=1500 if role=='youtube' else 800,port=port)
        plan.append(config);used.add(number);reserved.update(proxy_ports(config))
    return plan

def validate_template_plan(plan):
    installed=set(discover());numbers=set();ports=set();reserved=set()
    for number in installed:reserved.update(proxy_ports(load_config(number)))
    for config in plan:
        validate(config);number=config['instance'];wanted=proxy_ports(config)
        if number in installed or number in numbers:raise ValueError(f'Экземпляр {number} уже существует; выберите шаблон заново')
        if wanted&(ports|reserved):raise ValueError('SOCKS/HTTP-порты пересекаются: '+str(sorted(wanted&(ports|reserved))))
        if not ports_available(wanted):raise ValueError(f'Порт {config["port"]} или HTTP-порт {config["port"]+1} занят; выберите другую пару')
        numbers.add(number);ports.update(wanted)
    return plan

UPDATE_REPO='https://api.github.com/repos/Forcus356/Psiphon-Auto-Pin-Manager'

def version_key(value):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+',value):raise ValueError('Некорректная версия')
    return tuple(map(int,value.split('.')))

def installed_version(instance):
    try:
        text=(paths(instance)['app']/'autopin_menu.py').read_text()
        found=re.search(r"^VERSION='([0-9]+\.[0-9]+\.[0-9]+)'$",text,re.M)
        return found.group(1) if found else VERSION
    except OSError:return VERSION

class UpdateRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        if not newurl.startswith(UPDATE_REPO+'/'):
            raise ValueError('Неожиданный адрес перенаправления GitHub')
        return super().redirect_request(req,fp,code,msg,headers,newurl)

def update_json(url):
    if not url.startswith(UPDATE_REPO+'/'):raise ValueError('Недопустимый источник обновления')
    request=urllib.request.Request(url,headers={'Accept':'application/vnd.github+json','User-Agent':'Forcus-Auto-Pin-Updater','X-GitHub-Api-Version':'2022-11-28'})
    with urllib.request.build_opener(UpdateRedirects()).open(request,timeout=30) as response:
        data=response.read(2*1024*1024+1)
    if len(data)>2*1024*1024:raise ValueError('Ответ GitHub превышает допустимый размер')
    obj=json.loads(data)
    if not isinstance(obj,dict):raise ValueError('Некорректный ответ GitHub')
    return obj

def fetch_update(destination):
    """Resolve once, verify the immutable Git blob, then syntax-check privately."""
    commit=update_json(UPDATE_REPO+'/commits/main').get('sha','')
    if not isinstance(commit,str) or not re.fullmatch('[0-9a-f]{40}',commit):raise ValueError('GitHub не вернул корректный коммит')
    obj=update_json(UPDATE_REPO+'/contents/install_psiphon_autopin.sh?ref='+commit)
    if obj.get('type')!='file' or obj.get('path')!='install_psiphon_autopin.sh' or obj.get('encoding')!='base64':
        raise ValueError('Неожиданный файл обновления')
    raw=base64.b64decode(str(obj.get('content','')).replace('\n',''),validate=True)
    if not raw or len(raw)>1024*1024:raise ValueError('Некорректный размер установщика')
    digest=hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest()
    if digest!=obj.get('sha'):raise ValueError('Git blob checksum mismatch; update rejected')
    source=raw.decode('utf-8')
    found=re.search(r'^# Forcus Psiphon Auto-Pin Manager v([0-9]+\.[0-9]+\.[0-9]+)$',source,re.M)
    menu_version=re.search(r"^VERSION='([0-9]+\.[0-9]+\.[0-9]+)'$",source,re.M)
    if not found or not menu_version or found.group(1)!=menu_version.group(1) or 'autopin_install_main() {' not in source or '\0' in source:
        raise ValueError('Не распознан согласованный установщик Forcus Auto-Pin')
    destination=Path(destination)
    with destination.open('xb') as output:
        os.chmod(destination,0o600);output.write(raw);output.flush();os.fsync(output.fileno())
    result=subprocess.run(['bash','-n',str(destination)],capture_output=True,text=True,timeout=20)
    if result.returncode:raise ValueError('Ошибка синтаксиса установщика: '+safe_text(result.stderr[-200:]))
    return {'version':found.group(1),'commit':commit,'blob_sha1':digest,'sha256':hashlib.sha256(raw).hexdigest(),'path':str(destination)}

def installer_for(instance,fallback=None):
    candidates=[Path(fallback)] if fallback else []
    candidates.append(paths(instance)['app']/'install_psiphon_autopin.sh')
    candidates.extend(paths(n)['app']/'install_psiphon_autopin.sh' for n in discover())
    for path in candidates:
        if path.is_file():return path
    raise RuntimeError('Локальный установщик не найден. Запустите новый install_psiphon_autopin.sh для обновления.')

def build_args(config):
    validate(config)
    args=['--instance',str(config['instance']),'--region',config['region'] or 'AUTO',
          '--connection',config['connection_type'],'--menu-mode',config['menu_mode']]
    for key,flag in [('port','--port'),('bind','--bind'),('backend','--backend'),
        ('tunnel_pool','--tunnel-pool'),('min_speed_kib','--min-speed'),('probe_mb','--probe-mb'),
        ('slow_threshold','--slow-threshold'),('fail_threshold','--fail-threshold'),
        ('interval','--interval'),('wait','--wait'),('delay','--delay')]:
        args.extend([flag,str(int(config[key])) if key=='min_speed_kib' else str(config[key])])
    if config['region_pool']:args.extend(['--region-pool',','.join(config['region_pool'])])
    args.extend(['--deny-regions',' '.join(config['deny_regions'])])
    for key,on,off in [('gemini_check','--gemini-check','--no-gemini-check'),
        ('publish_http','--http','--no-http'),('strict_region','--strict-region','--no-strict-region'),
        ('impersonate','--impersonate','--no-impersonate'),('youtube_mode','--youtube-mode','--no-youtube-mode')]:
        args.append(on if config[key] else off)
    return args

def connection(config):
    if config['connection_type']=='socks5':return {'type':'socks5','uri':f'socks5h://{config["bind"]}:{config["port"]}'}
    suffix='' if config['instance']==1 else '-'+str(config['instance'])
    return {'type':'xray','outbound':{'tag':'psiphon-out'+suffix,'protocol':'socks',
        'settings':{'servers':[{'address':config['bind'],'port':config['port']}]}}}

def atomic_json(path,value):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    temp=None
    try:
        with tempfile.NamedTemporaryFile('w',dir=path.parent,delete=False) as f:
            temp=f.name;json.dump(value,f,ensure_ascii=False,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
        os.chmod(temp,0o600);os.replace(temp,path)
        directory=os.open(path.parent,os.O_RDONLY|os.O_DIRECTORY)
        try:os.fsync(directory)
        finally:os.close(directory)
    finally:
        if temp and Path(temp).exists():Path(temp).unlink()

def write_connection(config):
    data=paths(config['instance'])['data'];value=connection(config)
    atomic_json(data/'connection.json',value)
    if value['type']=='xray':atomic_json(data/'xray-outbound.json',value['outbound'])
    else:(data/'xray-outbound.json').unlink(missing_ok=True)
    return value

def watchdog_period(seconds):
    minutes,remainder=divmod(int(seconds),60)
    return f'{minutes} мин'+(f' {remainder} с' if remainder else '')

def display(field,value):
    if field.kind=='minutes':return str(int(value)//60) if int(value)%60==0 else watchdog_period(value)
    if field.kind=='bool':return 'да' if value else 'нет'
    if field.key=='connection_type':return 'SOCKS5 (адрес)' if value=='socks5' else 'Xray (outbound JSON)'
    if isinstance(value,list):return ','.join(value) or 'пусто'
    if field.key=='region' and not value:return 'AUTO'
    return str(value)

def safe_text(value):
    text=str(value)
    text=re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]','',text)
    return ''.join(c if c.isprintable() else ' ' for c in text)

def cells(text):
    return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in text)

def wrapped(text,width):
    """Wrap by terminal cells, preserving words and wide Unicode characters."""
    text=safe_text(text);lines=[];line=''
    for word in text.split():
        if line and cells(line+' '+word)<=width:line+=' '+word;continue
        if line:lines.append(line);line=''
        for char in word:
            if line and cells(line+char)>width:lines.append(line);line=''
            line+=char
    if line or not lines:lines.append(line)
    return lines

class ConsoleStyle:
    COLORS={'green':'92','cyan':'96','yellow':'93','red':'91','normal':'97','bold':'1'}
    def __init__(self,terminal,width=None,color=None):
        try:tty=os.isatty(terminal.fileno())
        except (AttributeError,OSError,ValueError):tty=False
        try:columns=os.get_terminal_size(terminal.fileno()).columns
        except (AttributeError,OSError,ValueError):columns=shutil.get_terminal_size((80,24)).columns
        self.width=max(28,min(78,(width if width is not None else columns)-2))
        self.color=(tty and os.environ.get('TERM','')!='dumb' and 'NO_COLOR' not in os.environ) if color is None else color
        self.ascii=os.environ.get('TERM','')=='dumb'
    def paint(self,text,tone):
        return '\033['+self.COLORS[tone]+'m'+text+'\033[0m' if self.color else text
    def box(self,title,sections):
        horizontal='-' if self.ascii else '─';vertical='|' if self.ascii else '│'
        corners=('+','+','+','+','+','+') if self.ascii else ('┌','┐','├','┤','└','┘')
        inner=self.width-4;lines=[]
        def rule(left,right):lines.append(self.paint(left+horizontal*(self.width-2)+right,'green'))
        def row(text,tone=None):
            for part in wrapped(text,inner):
                content=' '+part+' '*(inner-cells(part)+1)
                lines.append(self.paint(vertical,'green')+(self.paint(content,tone) if tone else content)+self.paint(vertical,'green'))
        rule(*corners[:2]);row(title,'bold')
        for heading,items in sections:
            rule(*corners[2:4])
            if heading:row(heading,'cyan')
            for item in items:row(item)
        rule(*corners[4:]);return '\n'.join(lines)
    def info(self,text,tone='normal'):
        return '\n'.join(self.paint(line,tone) for line in wrapped(text,self.width))

def runtime_status(instance,backend):
    suffix='' if instance==1 else '-'+str(instance)
    monitor='psiphon-autopin'+suffix+'.service';tunnel='vps-psiphon'+suffix+'.service'
    units=[monitor] if backend=='console' else [tunnel,monitor]
    result={}
    try:
        p=subprocess.run(['systemctl','show',*units,'-p','Id','-p','LoadState','-p','ActiveState','-p','UnitFileState'],capture_output=True,text=True,timeout=2)
        for section in p.stdout.strip().split('\n\n'):
            values=dict(line.split('=',1) for line in section.splitlines() if '=' in line)
            if values.get('Id'):result[values['Id']]=values
    except (OSError,subprocess.TimeoutExpired):pass
    def value(unit):
        data=result.get(unit,{})
        return {'state':data.get('ActiveState','unknown') if data.get('LoadState')!='not-found' else 'not-found','autostart':data.get('UnitFileState','unknown')}
    status={'monitor':value(monitor),'tunnel':value(tunnel)}
    if backend=='console':
        try:
            p=subprocess.run(['docker','inspect','-f','{{.State.Running}}','vps-psiphon'+suffix],capture_output=True,text=True,timeout=2)
            status['tunnel']['state']='active' if p.returncode==0 and p.stdout.strip()=='true' else 'inactive' if p.returncode==0 else 'not-found'
        except (OSError,subprocess.TimeoutExpired):pass
    try:
        p=subprocess.run(['docker','inspect','-f','{{.State.StartedAt}}','vps-psiphon'+suffix],capture_output=True,text=True,timeout=2)
        status['tunnel']['started_at']=p.stdout.strip() if p.returncode==0 else None
    except (OSError,subprocess.TimeoutExpired):status['tunnel']['started_at']=None
    return status

def read_state(instance):
    try:
        value=json.loads((paths(instance)['data']/'state.json').read_text())
        return value if isinstance(value,dict) else {}
    except (OSError,ValueError):return {}

def status_label(value):
    return {'active':('работает','green'),'inactive':('остановлен','red'),'failed':('ошибка','red'),
        'activating':('запускается','yellow'),'deactivating':('останавливается','yellow'),
        'not-found':('не установлен','yellow')}.get(value,('неизвестно','yellow'))

def autostart_label(value):
    return {'enabled':'да','enabled-runtime':'до перезагрузки','disabled':'нет','static':'по зависимости','masked':'заблокирован'}.get(value,'неизвестно')

class Menu:
    def __init__(self,terminal,instance=1,installer=None,emit_args=None):
        self.terminal=terminal;self.instance=instance;self.installer=installer or Path(__file__).with_name('install_psiphon_autopin.sh');self.emit_args=emit_args
        self.config=load_config(instance)
        self.style=ConsoleStyle(terminal);self._status_cache=None;self._speed_edited=False
    def say(self,text=''):print(text,file=self.terminal,flush=True)
    def ask(self,prompt):
        while True:
            self.terminal.write(prompt);self.terminal.flush();answer=self.terminal.readline()
            if not answer:raise EOFError
            if '\ufffd' in answer:
                self.say('Некорректная кодировка ввода. Повторите ввод; для выбора используйте латиницу или цифры.')
                continue
            return answer.strip()
    def confirm(self,text):
        self.say('Введите y — да, n — нет; Enter — отменить. Также можно 1 / 0.')
        while True:
            answer=self.ask(text+' [y/n, по умолчанию n]: ').lower()
            if not answer or answer in FALSE:return False
            if answer in TRUE:return True
            self.say('Введите y или 1 для подтверждения, n или 0 для отмены.')
    def input_field(self,field,value):
        self.say(field.help)
        if field.choices:self.say(' / '.join(f'{n}. {v}' for n,v in enumerate(field.choices,1)))
        if field.kind=='bool':
            self.say('1 — Да (включить), 0 — Нет (выключить). Можно также да/нет или y/n.')
            prompt=f'{field.label} [1 — да / 0 — нет; Enter — оставить «{display(field,value)}»]: '
        else:prompt=f'{field.label} [{display(field,value)}], Enter — оставить: '
        text=self.ask(prompt)
        self._field_entered=bool(text)
        return parse_field(field,text) if text else value
    def overview(self):
        numbers=discover()
        if not numbers:
            self.footer();return
        self.say('Состояние всех установленных экземпляров. Настройки меняются только у выбранного: '+str(self.instance)+'. Пункт 4 — выбрать другой.')
        for title,items in [('====== Шаблоны ======',[n for n in numbers if instance_origin(n)]),
                            ('====== Ваши экземпляры ======',[n for n in numbers if not instance_origin(n)])]:
            if not items:continue
            self.say(self.style.info(title,'cyan'))
            for number in items:
                try:self.say(instance_label(number))
                except (ValueError,OSError,TypeError) as exc:self.say(f'Экземпляр {number}: ошибка настроек — '+safe_text(str(exc)))
            for number in items:
                try:self.footer(number,overview=True)
                except (ValueError,OSError,TypeError) as exc:self.say(f'Экземпляр {number}: состояние недоступно — '+safe_text(str(exc)))
    def view_targets(self,label,allow_all=True):
        numbers=discover()
        if len(numbers)<=1:return numbers
        rows=[instance_label(n)+(' · шаблон' if instance_origin(n) else ' · свой экземпляр') for n in numbers]
        self.panel(label+' · выбрать экземпляр',[('',rows+(['a. Все экземпляры'] if allow_all else [])+['0. Отмена'])])
        while True:
            answer=self.ask('Номер экземпляра'+(' или a — все' if allow_all else '')+' [0 — отмена]: ').lower()
            if answer=='0':return []
            if allow_all and answer in ('a','all','все'):return numbers
            try:
                number=valid_instance(answer)
                if number in numbers:return [number]
            except (ValueError,TypeError):pass
            self.say('Выберите установленный экземпляр из списка'+(' или a для всех.' if allow_all else '.'))
    def group_existing(self):
        numbers=discover()
        self.say('Для старых версий без отметки шаблона можно указать происхождение вручную. Настройки и службы не меняются.')
        for number in numbers:self.say(instance_label(number))
        try:
            answer=self.ask('Номера экземпляров одного шаблона через запятую [0 — отмена]: ')
            if answer=='0':return False
            selected=list(dict.fromkeys(valid_instance(v.strip()) for v in answer.split(',')))
            if not selected or any(n not in numbers for n in selected):raise ValueError('Нужны номера установленных экземпляров')
            if not self.confirm('Показать выбранные экземпляры в разделе «Шаблоны»?'):return False
            mark_template(selected);self.say('Группировка сохранена. Политики, порты и службы не изменены.');return False
        except (ValueError,OSError) as exc:self.say('Группировка: '+str(exc));return False
    def panel(self,title,sections):
        self.say('\n'+self.style.box(title,sections))
    def footer(self,instance=None,overview=False):
        number=self.instance if instance is None else instance
        saved=load_config(number);installed=paths(number)['manager'].is_file()
        state=read_state(number)
        key=(number,saved['backend'])
        if installed:
            if self._status_cache is None or self._status_cache[0]!=key or time.monotonic()-self._status_cache[1]>2:
                self._status_cache=(key,time.monotonic(),runtime_status(number,saved['backend']))
            status=self._status_cache[2]
        else:status={name:{'state':'not-found','autostart':'unknown'} for name in ('tunnel','monitor')}
        activity={}
        try:
            activity=json.loads((paths(number)['data']/'activity.json').read_text())
            if not isinstance(activity,dict):activity={}
        except (OSError,ValueError):pass
        searching=False
        try:
            searching=activity.get('status')=='SEARCHING' and status['monitor']['state']=='active' and dt.datetime.fromisoformat(activity['checked_at'])>=dt.datetime.fromisoformat(status['tunnel']['started_at'].replace('Z','+00:00'))
        except (KeyError,ValueError,TypeError):pass
        fresh=False
        try:
            last=dt.datetime.fromisoformat(state['verified_at'].replace('Z','+00:00'))
            began=dt.datetime.fromisoformat(status['tunnel']['started_at'].replace('Z','+00:00'))
            fresh=status['tunnel']['state']=='active' and last>=began
        except (KeyError,ValueError,TypeError,AttributeError):pass
        if searching:fresh=False
        self.say(self.style.info('--------- '+mode_label(saved)+' · экземпляр '+str(number)+' ---------','cyan'))
        tunnel,tone=status_label(status['tunnel']['state']);monitor,monitor_tone=status_label(status['monitor']['state'])
        combined='green' if tone==monitor_tone=='green' else 'red' if 'red' in (tone,monitor_tone) else 'yellow'
        self.say(self.style.info('Туннель: '+tunnel+'  ·  Монитор: '+monitor,combined))
        if installed:
            auto='монитор '+autostart_label(status['monitor']['autostart'])
            if saved['backend']!='console':auto='туннель '+autostart_label(status['tunnel']['autostart'])+' / '+auto
            self.say(self.style.info('Автозапуск: '+auto))
        mode='пул, задано '+str(saved['tunnel_pool']) if saved['tunnel_pool']>1 else 'PIN подготовлен' if state.get('pin_prepared') else 'PIN закреплён' if fresh and state.get('diagnostic_id') and state.get('adopted_unpinned') is False else 'проверка IP' if installed else 'один туннель'
        self.say(self.style.info('Регион: '+(saved['region'] or 'AUTO')+'  ·  Режим: '+mode))
        endpoint=saved['bind']+':'+str(saved['port'])
        self.say(self.style.info('SOCKS5: '+endpoint+'  ·  HTTP: '+(str(saved['port']+1) if saved['publish_http'] else 'выключен')))
        if state:
            self.say(self.style.info('Последний IP: '+str(state.get('ip') or 'нет данных')+'  ·  Google: '+str(state.get('google_region') or 'неизвестно')))
        gemini=str(state.get('gemini') or 'нет проверки') if saved['gemini_check'] else 'выключен'
        if saved['gemini_check'] or not overview:
            if saved['gemini_check'] and not fresh:
                self.say(self.style.info('Gemini: проверка / поиск IP; ответ модели ещё не подтверждён','yellow'))
                if state.get('gemini'):self.say(self.style.info('Предыдущий результат Gemini: '+gemini))
            else:
                self.say(self.style.info('Gemini: '+gemini,'green' if gemini=='SERVING' else 'red' if gemini in ('REFUSED','CAPTCHA') else 'yellow' if saved['gemini_check'] else 'normal'))
                if saved['gemini_check'] and gemini=='INCONCLUSIVE':self.say(self.style.info('Ответ модели Gemini не подтверждён; PIN подтверждает только закрепление сервера.','yellow'))
        if state.get('verified_at'):
            verified=str(state['verified_at'])
            try:verified=dt.datetime.fromisoformat(verified.replace('Z','+00:00')).astimezone(dt.timezone.utc).strftime('%d.%m.%Y %H:%M:%S UTC')
            except ValueError:pass
            self.say(self.style.info('Последняя проверка: '+verified))
        yt_path=paths(number)['data']/'youtube-status.json'
        yt={}
        if saved['youtube_mode']:
            try:yt=json.loads(yt_path.read_text())
            except (OSError,ValueError):pass
            try:
                age=(dt.datetime.now(dt.timezone.utc)-dt.datetime.fromisoformat(yt['checked_at'])).total_seconds()
                boot=located('/proc/sys/kernel/random/boot_id').read_text().strip()
                if not 0<=age<=max(600,2*saved['interval']) or yt.get('boot_id')!=boot or (yt.get('status') in ('RU VERIFIED','PIN VERIFIED') and yt.get('container_started_at')!=status['tunnel'].get('started_at')):yt['status']='UNKNOWN'
            except (KeyError,ValueError,TypeError,OSError):yt['status']='UNKNOWN'
        label=yt.get('status','UNKNOWN') if saved['youtube_mode'] else 'DISABLED'
        if saved['youtube_mode'] or not overview:
            self.say(self.style.info('YouTube Mode: '+label,'green' if label in ('RU VERIFIED','PIN VERIFIED') else 'yellow' if saved['youtube_mode'] else 'normal'))
        if saved['youtube_mode']:
            self.say(self.style.info('Последний YouTube IP: '+str(yt.get('ip') or 'нет данных')+' · Google: '+str(yt.get('google_region') or 'UNKNOWN')))
            self.say(self.style.info('ID: '+str(yt.get('diagnostic_id') or 'нет данных')+' · Скорость: '+str(yt.get('speed_kib_s') if yt.get('speed_kib_s') is not None else 'нет данных')+' KiB/s'))
            self.say(self.style.info('Последняя успешная RU-проверка: '+str(yt.get('last_success_at') or 'нет данных')))
        if searching:
            self.say(self.style.info('Поиск: '+str(activity.get('detail') or 'подбор подходящего выхода'),'yellow'))
        self.say(self.style.info('Watchdog: интервал '+watchdog_period(saved['interval'])))
        output='SOCKS5' if saved['connection_type']=='socks5' else 'Xray JSON'
        current=installed_version(number) if installed else VERSION
        ui='' if current==VERSION else ' · Меню: v'+VERSION
        self.say(self.style.info('Скрипт: v'+current+ui+'  ·  Формат: '+output,'cyan'))
        dirty=number==self.instance and any(self.config.get(f.key)!=saved.get(f.key) for f in FIELDS)
        ready=fresh if not saved['youtube_mode'] else label in ('RU VERIFIED','PIN VERIFIED') and status['tunnel']['state']=='active' and status['monitor']['state']=='active'
        if installed and not ready:
            waiting=status['monitor']['state'] in ('active','activating')
            self.say(self.style.info('Проверка / поиск IP выполняется; результат ещё не подтверждён.' if waiting else 'Нет подтверждённого результата для текущего запуска.','yellow'))
        if dirty:self.say(self.style.info('Есть изменения, ещё не применены.','yellow'))
        elif not installed:self.say(self.style.info('Экземпляр ещё не установлен. Выберите настройки.','yellow'))
        self.say()
    def edit(self,mode):
        self.config['menu_mode']=mode
        by_key={field.key:field for field in FIELDS}
        while True:
            fields=list(FIELDS) if mode=='advanced' else [by_key[key] for key in EASY_KEYS]+([by_key['min_speed_kib']] if self.config['youtube_mode'] else [])
            groups=[]
            headings=({0:'ОСНОВНОЕ',4:'WATCHDOG',5:'YOUTUBE',6:'СКОРОСТЬ ВИДЕО'} if mode=='easy' else {0:'ОСНОВНОЕ',4:'СЕТЬ',6:'СТРАНЫ И ТУННЕЛИ',10:'СКОРОСТЬ',13:'МОНИТОРИНГ',17:'СОВМЕСТИМОСТЬ',19:'YOUTUBE'})
            for index,field in enumerate(fields):
                if index in headings:groups.append((headings[index],[]))
                groups[-1][1].append(f'{index+1:2}. {field.label}: {display(field,self.config[field.key])}')
            groups.append(('', ['y. Просмотреть и применить','0. Назад без применения']))
            self.panel(f'{mode.title()} Mode · экземпляр {self.instance}',groups)
            self.footer()
            answer=self.ask('Выбор: ').lower()
            if answer=='0':return False
            if answer=='y':
                if self.apply():return True
                continue
            try:
                index=int(answer)
                if not 1<=index<=len(fields):raise ValueError
                field=fields[index-1]
                value=self.input_field(field,self.config[field.key])
                if self._field_entered:
                    if field.key=='min_speed_kib':self._speed_edited=True
                    if field.key in ('youtube_mode','gemini_check') and value:
                        if not self.enable_mode(field.key):continue
                    else:self.config[field.key]=value
                    if field.key=='region' and self.config['region_pool'] and value not in self.config['region_pool']:
                        self.config['region_pool']=[];self.say('Пул стран очищен: новая страна вне прежнего пула.')
                    if field.key=='region_pool' and value and self.config['region'] not in value:
                        self.config['region']=value[0];self.say('Выбрана первая страна из пула: '+value[0])
            except (ValueError,TypeError) as exc:self.say('Ошибка: '+(str(exc) or 'выберите номер из меню'))
    def templates(self):
        self.panel('Шаблоны · быстрый запуск',[
            ('ВЫБЕРИТЕ ЧТО ЗАПУСТИТЬ',[f'{key}. {label}' for key,(label,_) in TEMPLATES.items()]),
            ('',['g. Отметить существующие экземпляры как шаблон','0. Назад'])])
        self.say('Вариант 1 запускает оба режима одновременно: два экземпляра, два разных SOCKS-порта.')
        self.say('Шаблоны создают новые экземпляры. Уже установленные экземпляры продолжают работать без изменений.')
        while True:
            choice=self.ask('Выберите шаблон [1 / 2 / 3; g — группировка; 0 — назад]: ').lower()
            if choice=='0':return False
            if choice=='g':return self.group_existing()
            if choice in TEMPLATES:break
            self.say('Введите номер: 1, 2, 3 или 0.')
        try:plan=template_plan(choice,self.instance)
        except (ValueError,OSError) as exc:self.say('Не удалось подготовить шаблон: '+str(exc));return False
        by_key={field.key:field for field in FIELDS}
        while True:
            sections=[];editable=[]
            for config in plan:
                rows=[]
                for key in ('region','port','interval','connection_type')+(('min_speed_kib',) if config['youtube_mode'] else ()):
                    field=by_key[key];editable.append((config,field))
                    rows.append(f'{len(editable)}. {field.label}: {display(field,config[key])}')
                rows.append('Gemini: '+('да' if config['gemini_check'] else 'нет')+' · YouTube: '+('да' if config['youtube_mode'] else 'нет'))
                rows.append(f'HTTP: 127.0.0.1:{config["port"]+1} · один туннель')
                sections.append((mode_label(config)+' · экземпляр '+str(config['instance']),rows))
            sections.append(('', ['y. Установить выбранный шаблон','0. Назад без установки']))
            self.panel('Шаблон · '+TEMPLATES[choice][0],sections)
            self.say('Настройки уже готовы. Введите y для установки или номер строки для изменения.')
            answer=self.ask('Выбор [y — установить; 0 — назад]: ').lower()
            if answer=='0':return False
            if answer=='y':
                try:validate_template_plan(plan)
                except (ValueError,OSError) as exc:self.say('Ошибка: '+str(exc));continue
                return self.apply_template_plan(plan)
            try:
                index=int(answer)
                if not 1<=index<=len(editable):raise ValueError('Выберите номер строки')
                config,field=editable[index-1]
                config[field.key]=self.input_field(field,config[field.key])
            except (ValueError,TypeError) as exc:self.say('Ошибка: '+(str(exc) or 'выберите номер строки'))
    def apply_template_plan(self,plan):
        try:validate_template_plan(plan)
        except (ValueError,OSError) as exc:self.say('Шаблон не применён: '+str(exc));return False
        self.panel('Будут запущены',[
            ('', [f'{mode_label(c)} · экземпляр {c["instance"]} · SOCKS5 127.0.0.1:{c["port"]} · регион {c["region"] or "AUTO"}' for c in plan])])
        self.say('Установка выполняется по очереди. После неё оба монитора работают одновременно и ищут свои выходы в фоне.' if len(plan)>1 else 'После установки монитор ищет и проверяет подходящий выход в фоне.')
        if not self.confirm('Установить выбранный шаблон?'):
            self.say('Отменено; файлы и службы не изменены.');return False
        completed=[];group=uuid.uuid4().hex
        try:
            validate_template_plan(plan)
            args=[build_args(config) for config in plan]
            if self.emit_args:
                atomic_json(self.emit_args,args);return True
            installer=installer_for(plan[0]['instance'],self.installer)
            for config,argv in zip(plan,args):
                self.say(f'Установка {mode_label(config)} · экземпляр {config["instance"]}...')
                result=subprocess.run(['bash',str(installer),*argv],env={**os.environ,'AUTOPIN_MENU_PARENT':'1','AUTOPIN_CREATE_ONLY':'1'})
                if result.returncode:raise RuntimeError(f'{mode_label(config)}: установщик завершился с кодом {result.returncode}; проверьте журналы')
                completed.append(config)
                mark_template([config['instance']],group)
                self.instance=completed[0]['instance'];self.config=load_config(self.instance);self._status_cache=None;self._speed_edited=False
                self.say(f'{mode_label(config)} · экземпляр {config["instance"]}: установка завершена; подтверждение выхода выполняется монитором.')
        except (ValueError,OSError,RuntimeError) as exc:
            self.say('Шаблон установлен не полностью: '+str(exc))
            if completed:
                self.say('Уже установлены и сохранены: '+', '.join(f'{mode_label(c)} (экземпляр {c["instance"]})' for c in completed)+'.')
            self.say('Общий успех не подтверждён. Уже установленные экземпляры не удаляются; состояние доступно в главном меню.')
            return False
        self.say('Шаблон установлен. Запуск служб ещё не означает найденный и проверенный IP.')
        for config in plan:
            self.say(f'{mode_label(config)}: socks5h://127.0.0.1:{config["port"]} · меню: auto-pin --instance {config["instance"]}')
        self.say('Главное меню → 4 переключает отображаемый экземпляр. Остальные продолжают работать.')
        return True
    def enable_mode(self,key):
        other='gemini_check' if key=='youtube_mode' else 'youtube_mode'
        label='YouTube' if key=='youtube_mode' else 'Gemini'
        if self.config[other]:
            self.say('YouTube (Google RU) и Gemini работают на разных экземплярах и SOCKS-портах.')
            self.say('1. Настроить отдельный экземпляр для '+label+' (текущий не изменится)')
            self.say('2. Использовать текущий, отключив только его другой режим')
            self.say('0. Отмена')
            choice=self.ask('Выбор [Enter — 1]: ') or '1'
            if choice=='1':
                occupied=set(discover())|{self.instance};ports=set()
                for number in discover():
                    cfg=load_config(number);ports.add(cfg['port'])
                    if cfg['publish_http']:ports.add(cfg['port']+1)
                candidate=None
                for number in range(1,100):
                    if number in occupied:continue
                    port=40000+2*(number-1)
                    if {port,port+1}&ports:continue
                    sockets=[]
                    try:
                        for value in (port,port+1):
                            sock=socket.socket();sockets.append(sock);sock.bind(('127.0.0.1',value))
                    except OSError:continue
                    finally:
                        for sock in sockets:sock.close()
                    candidate=number;break
                if candidate is None:raise ValueError('Нет свободного экземпляра и пары портов')
                previous=self.instance;selected_mode=self.config['menu_mode'];self.instance=candidate;self.config=defaults(candidate)
                self.config.update(youtube_mode=(key=='youtube_mode'),gemini_check=(key=='gemini_check'),region='' if key=='youtube_mode' else 'NL',min_speed_kib=1500 if key=='youtube_mode' else 800,menu_mode=selected_mode)
                self._status_cache=None;self._speed_edited=False
                self.say(f'Настраивается новый экземпляр {candidate}, SOCKS {self.config["port"]}. Экземпляр {previous} не изменён. Примените настройки через y.')
                return True
            if choice!='2':return False
            if not self.confirm('Отключить другой режим только у текущего экземпляра?'):return False
        if key=='youtube_mode' and (self.config['tunnel_pool']!=1 or self.config['bind']!='127.0.0.1'):
            if not self.confirm('YouTube требует 1 туннель и 127.0.0.1. Установить эти значения?'):return False
            self.config.update(tunnel_pool=1,bind='127.0.0.1')
        if key=='youtube_mode' and not (paths(self.instance)['data']/'settings.json').exists() and not self._speed_edited:
            self.config['min_speed_kib']=1500
        self.config[key]=True;self.config[other]=False
        if key=='youtube_mode':self.say('Обязательная политика Google RU; сохранённые deny/strict параметры не удаляются. Регион Psiphon остаётся выбранным; AUTO расширяет поиск.')
        return True

    def apply(self):
        try:args=build_args(self.config)
        except (ValueError,TypeError) as exc:self.say('Ошибка настроек: '+str(exc));return False
        self.panel('Настройки к применению · экземпляр '+str(self.instance),[('',[field.label+': '+display(field,self.config[field.key]) for field in FIELDS])])
        self.say('Применение может перезапустить выбранный туннель. Настройки сохранятся в settings.json.')
        if not self.confirm('Применить эти настройки?'):self.say('Отменено; файлы и службы не изменены.');return False
        if self.emit_args:
            atomic_json(self.emit_args,args)
            return True
        try:
            installer=installer_for(self.instance,self.installer)
            result=subprocess.run(['bash',str(installer),*args],env={**os.environ,'AUTOPIN_MENU_PARENT':'1'})
            if result.returncode:
                self.say(f'Установщик завершился с кодом {result.returncode}; сохранение новых настроек не подтверждено. Проверьте журналы.')
                return False
            self.config=load_config(self.instance);self._status_cache=None;self._speed_edited=False
            self.show_connection();return True
        except (OSError,RuntimeError) as exc:self.say('Ошибка применения: '+str(exc));return False
    def update(self):
        if not paths(self.instance)['manager'].is_file():
            self.say('Сначала установите этот экземпляр через Easy или Advanced.');return False
        self.say('Получаю установщик из Forcus356/Psiphon-Auto-Pin-Manager...')
        self.say('Будут сохранены установленные настройки выбранного экземпляра; несохранённые правки меню не применяются.')
        try:
            with tempfile.TemporaryDirectory(prefix='autopin-update-') as tmp:
                info=fetch_update(Path(tmp)/'install.sh')
                current=installed_version(self.instance)
                if version_key(info['version'])<max(version_key(VERSION),version_key(current)):
                    raise ValueError('На GitHub версия '+info['version']+' старее установленной. Откат запрещён; сначала опубликуйте новую версию в репозитории.')
                self.panel('Обновление · экземпляр '+str(self.instance),[('',[
                    'Версия: '+current+' → '+info['version'],
                    'Коммит: '+info['commit'],
                    'SHA-256: '+info['sha256']])])
                if not self.confirm('Обновить этот экземпляр с сохранением настроек?'):
                    self.say('Отменено; установщик не запускался.');return False
                result=subprocess.run(['bash',info['path'],'--instance',str(self.instance)],env={**os.environ,'AUTOPIN_MENU_PARENT':'1'})
                if result.returncode:
                    self.say('Обновление не подтверждено: установщик завершился с кодом '+str(result.returncode)+'. Проверьте журнал и резервную копию на VPS.');return False
                receipt={k:v for k,v in info.items() if k!='path'}
                receipt['updated_at']=dt.datetime.now(dt.timezone.utc).isoformat()
                atomic_json(paths(self.instance)['data']/'update-source.json',receipt)
                self.say('Обновление завершено.')
                return True
        except (OSError,ValueError,RuntimeError,subprocess.SubprocessError) as exc:
            self.say('Обновление: '+safe_text(str(exc)));return False

    def update_selected(self):
        targets=self.view_targets('Обновление')
        if not targets:return False
        done=[]
        for number in targets:
            self.instance=number;self.config=load_config(number);self._status_cache=None
            self.say('Обновление: '+instance_label(number))
            if not self.update():
                self.say('Обновление '+str(number)+' не подтверждено. Остальные ещё не выбранные экземпляры не обновлялись.')
                break
            done.append(number)
        if done:
            self.instance=done[-1];self.config=load_config(self.instance)
            self.say('Обновлены экземпляры: '+', '.join(map(str,done)))
        return bool(done)

    def reopen(self):
        self.say('Открываю главное меню обновлённого экземпляра...')
        os.execv(sys.executable,[sys.executable,str(paths(self.instance)['app']/'autopin_menu.py'),'--instance',str(self.instance)])
        return 0

    def show_connection(self):
        value=connection(self.config);self.say('\nГотово. Подключение:')
        self.say(value['uri'] if value['type']=='socks5' else json.dumps(value['outbound'],ensure_ascii=False,indent=2))
        self.say('Настройки: '+str(paths(self.instance)['data']/'settings.json'))
        if value['type']=='xray':
            self.say('JSON: '+str(paths(self.instance)['data']/'xray-outbound.json'))
            self.say('Добавьте outbound и маршрутизацию в Xray. Его процесс должен иметь доступ к указанному адресу VPS.')
    def select_instance(self):
        self.say('Выбор экземпляра для настройки:')
        for number in discover():self.say(instance_label(number))
        try:
            value=valid_instance(self.ask('Номер экземпляра 1–99 (существующий или новый): '))
            config=load_config(value)
            self.instance=value;self.config=config;self._status_cache=None;self._speed_edited=False
        except (ValueError,OSError) as exc:self.say('Ошибка: '+str(exc))
    def manage(self):
        manager=paths(self.instance)['manager']
        if not manager.is_file():self.say('Этот экземпляр ещё не установлен. Выберите Easy или Advanced.');return False
        actions=[('Статус','status'),('Проверить соединение','check'),('Запустить','start'),
            ('Остановить','stop'),('Перезапустить','restart'),('Сменить сервер / ротация','rotate'),
            ('Поиск сервера / PIN','search'),('Показать журналы','logs'),('Измерить скорость','speed'),('Показать Xray JSON','xray'),
            ('Подготовить PIN','prepare-pin'),('Обновить кэш серверов','refresh-cache'),('Удалить этот экземпляр','uninstall'),('Удалить + принадлежащие скрипту Docker/Go','purge'),('Показать сохранённые настройки / конфиг','config')]
        self.panel('Управление · экземпляр '+str(self.instance),[
            ('СОСТОЯНИЕ И СЛУЖБЫ',[f'{index+1:2}. {label}' for index,(label,_) in enumerate(actions) if index<5]),
            ('ДИАГНОСТИКА И СЕРВЕРЫ',[f'{index+1:2}. {label}' for index,(label,_) in enumerate(actions) if 5<=index<12]),
            ('КОНФИГУРАЦИЯ',['15. Показать сохранённые настройки / конфиг']),
            ('УДАЛЕНИЕ',[f'{index+1:2}. {label}' for index,(label,_) in enumerate(actions) if 12<=index<14]+['0. Назад'])])
        self.footer();answer=self.ask('Выбор: ')
        if answer=='0':return False
        try:
            index=int(answer)
            if not 1<=index<=len(actions):raise ValueError
        except ValueError:self.say('Выберите номер из меню.');return False
        label,command=actions[index-1];extra=[]
        if command in ('status','logs','xray','config','check','speed'):
            targets=self.view_targets(label)
            if not targets:return False
        else:targets=[self.instance]
        if command=='logs':
            raw=self.ask('Строк журнала [50]: ')
            try:count=int(raw or '50');assert 1<=count<=10000
            except (ValueError,AssertionError):self.say('Нужно число 1–10000.');return False
            extra=[str(count)]
        if command=='refresh-cache':extra=['--allow-interruption']
        purge=(command=='purge')
        if purge:
            command='uninstall';extra=['--purge-deps']
            self.say('Docker/Go удаляются только при наличии журнала установки скриптом и отсутствии других потребителей. Существовавшие ранее зависимости сохраняются.')
        if command in ('stop','restart','rotate','search','refresh-cache','uninstall'):
            warning='Удалятся службы, контейнер и данные только выбранного экземпляра.' if command=='uninstall' else 'Это действие может прервать соединения выбранного экземпляра.'
            self.say(warning)
            if not self.confirm(label+'?'):return False
        try:
            result=None
            for number in targets:
                self.say('\n===== '+instance_label(number)+' · '+label+' =====')
                target=paths(number)['manager']
                if not target.is_file():self.say('Менеджер экземпляра отсутствует.');continue
                # Read-only config is rendered by the current UI, including for old managers.
                if command=='config':
                    self.say(json.dumps({'instance':number,'name':mode_label(load_config(number)),'origin':instance_origin(number),
                        'settings':load_config(number),'connection':connection(load_config(number))},ensure_ascii=False,indent=2))
                    continue
                result=subprocess.run([sys.executable,str(target),command,*extra,'--instance',str(number)])
                self.say('Код завершения: '+str(result.returncode))
            self._status_cache=None
            return command=='uninstall' and result is not None and result.returncode==0
        except OSError as exc:self.say('Ошибка запуска: '+str(exc));return False
    def run(self):
        while True:
            self.panel(f'Forcus Auto-Pin {VERSION} · экземпляр {self.instance}',[
                ('БЫСТРЫЙ ЗАПУСК',['t. Шаблоны — Gemini / YouTube / оба вместе']),
                ('НАСТРОЙКА',['1. Easy Mode — основные настройки','2. Advanced Mode — все настройки']),
                ('ОБСЛУЖИВАНИЕ',['3. Управление и диагностика','4. Выбрать / создать экземпляр']),
                ('ОБНОВЛЕНИЕ',['5. Обновить Auto-Pin (GitHub)']),
                ('', ['r. Обновить состояние','0. Выход'])])
            installed=discover()
            self.overview()
            first_install=not installed
            answer=self.ask('Выбор [Enter — '+('Шаблоны' if first_install else self.config['menu_mode'].title())+']: ').lower()
            if answer=='':answer='t' if first_install else '1' if self.config['menu_mode']=='easy' else '2'
            if answer=='0':return 0
            if answer=='t':
                if self.templates() and self.emit_args:return 0
            elif answer in ('1','2'):
                applied=self.edit('easy' if answer=='1' else 'advanced')
                if applied and self.emit_args:return 0
            elif answer=='3':
                if self.manage():return 0
            elif answer=='4':self.select_instance()
            elif answer=='5':
                if self.update_selected():return self.reopen()
            elif answer=='r':self._status_cache=None
            else:self.say('Выберите номер из меню.')

class TerminalIO:
    """A terminal is not seekable; use separate read and write streams."""
    def __init__(self,reader,writer):self.reader=reader;self.writer=writer
    def fileno(self):return self.writer.fileno()
    def write(self,text):return self.writer.write(text)
    def flush(self):self.writer.flush()
    def readline(self):return self.reader.readline()

def main(argv=None):
    parser=argparse.ArgumentParser(description='Forcus Auto-Pin Easy / Advanced menu')
    parser.add_argument('--instance',type=int)
    parser.add_argument('--installer',type=Path)
    parser.add_argument('--update',action='store_true')
    parser.add_argument('--emit-args',type=Path,help=argparse.SUPPRESS)
    args=parser.parse_args(argv)
    if os.geteuid()!=0:print('Запустите меню от root: sudo auto-pin',file=sys.stderr);return 1
    try:
        instance=valid_instance(args.instance) if args.instance is not None else (discover() or [1])[0]
        with open('/dev/tty','r',encoding='utf-8',errors='replace') as reader, open('/dev/tty','w',encoding='utf-8',buffering=1) as writer:
            menu=Menu(TerminalIO(reader,writer),instance,args.installer,args.emit_args)
            return (menu.reopen() if menu.update_selected() else 1) if args.update else menu.run()
    except (KeyboardInterrupt,EOFError):return 0
    except (ValueError,OSError,RuntimeError) as exc:print('Меню: '+str(exc),file=sys.stderr);return 1

if __name__=='__main__':raise SystemExit(main())
PY_MENU
}
MENU_REQUESTED=0
for menu_arg in "$@"; do
    if [[ $menu_arg == --menu || $menu_arg == --interactive ]]; then MENU_REQUESTED=1; fi
done
if (( $# == 0 )) && [[ -t 1 ]]; then
    if ( : </dev/tty ) 2>/dev/null; then MENU_REQUESTED=1; fi
fi
if (( MENU_REQUESTED )); then
    menu_options=()
    while (($#)); do
        case "$1" in
            --menu|--interactive) shift ;;
            --instance) menu_options+=(--instance "${2:?Missing instance}"); shift 2 ;;
            *) echo 'Use --menu with optional --instance N, or use ordinary flags without --menu.' >&2; return 2 ;;
        esac
    done
    if ! command -v python3 >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y python3
    fi
    menu_tmp=$(mktemp -d)
    write_menu_module > "$menu_tmp/autopin_menu.py"
    # Keep the complete installer available for every instance in a template.
    # The menu owns child installs, so no child opens another menu or holds its lock.
    {
        printf '#!/usr/bin/env bash\n# Forcus Auto-Pin offline installer v4.4.0\n'
        declare -f autopin_install_main
        printf '\nautopin_install_main "$@"\n'
    } > "$menu_tmp/install_psiphon_autopin.sh"
    menu_rc=0
    python3 "$menu_tmp/autopin_menu.py" "${menu_options[@]}" --installer "$menu_tmp/install_psiphon_autopin.sh" || menu_rc=$?
    rm -rf "$menu_tmp"
    return "$menu_rc"
fi
write_system_module() {
cat <<'PY_SYSTEM'
#!/usr/bin/env python3
"""Receipts for Docker/Go installed by Auto-Pin; conservative dependency cleanup."""
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT=Path('/')
GROUPS={
    'docker':re.compile(r'^(docker\.io|docker-ce|docker-ce-cli|docker-ce-rootless-extras|docker-buildx-plugin|docker-compose-plugin|containerd\.io|containerd|runc)$'),
    'go':re.compile(r'^(golang-go|golang-src|golang-[0-9][0-9.]*-(go|src))$'),
}

def system_dir():return ROOT/'var/lib/psiphon-autopin-system'
def ledger_path():return system_dir()/'dependencies.json'
def load_ledger():
    if not ledger_path().exists():return {'version':1,'components':{}}
    data=json.loads(ledger_path().read_text())
    if data.get('version')!=1 or not isinstance(data.get('components'),dict):raise ValueError('Invalid dependency receipt; dependencies will be retained')
    for component,receipt in data['components'].items():
        if component not in GROUPS or not isinstance(receipt,dict) or not isinstance(receipt.get('packages'),list):raise ValueError('Invalid dependency receipt')
        if any(not isinstance(p,str) or not GROUPS[component].fullmatch(p) for p in receipt['packages']):raise ValueError('Unexpected package in dependency receipt')
    return data

def save_ledger(data):
    folder=system_dir();folder.mkdir(parents=True,exist_ok=True,mode=0o700);folder.chmod(0o700)
    name=None
    try:
        with tempfile.NamedTemporaryFile('w',dir=folder,delete=False) as f:
            name=f.name;json.dump(data,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
        os.chmod(name,0o600);os.replace(name,ledger_path())
    finally:
        if name and Path(name).exists():Path(name).unlink()

@contextlib.contextmanager
def locked():
    folder=system_dir();folder.mkdir(parents=True,exist_ok=True,mode=0o700)
    with (folder/'dependencies.lock').open('a') as lock:
        os.chmod(lock.name,0o600);fcntl.flock(lock,fcntl.LOCK_EX)
        yield

def inventory():
    p=subprocess.run(['dpkg-query','-W','-f=${binary:Package}\t${db:Status-Status}\n'],capture_output=True,text=True,timeout=30)
    if p.returncode:raise RuntimeError('Cannot determine installed packages; dependencies retained')
    result=set()
    for line in p.stdout.splitlines():
        parts=line.split('\t')
        if len(parts)==2 and parts[1]=='installed':result.add(parts[0].split(':',1)[0])
    return result

def install(component,packages,lock_held=False):
    if component not in (*GROUPS,'tools'):raise ValueError('Unknown component')
    if not packages or any(not re.fullmatch(r'[a-z0-9][a-z0-9+.-]*',p) for p in packages):raise ValueError('Invalid package names')
    with (contextlib.nullcontext() if lock_held else locked()):
        ledger=load_ledger();before=inventory()
        preexisting=False
        if component in GROUPS:
            binary='docker' if component=='docker' else 'go'
            roots={'docker.io','docker-ce','docker-ce-cli'} if component=='docker' else {p for p in before if p=='golang-go' or re.fullmatch(r'golang-[0-9][0-9.]*-go',p)}
            preexisting=bool(shutil.which(binary)) or bool(roots&before)
        try:
            p=subprocess.run(['apt-get','install','-y',*packages],env={**os.environ,'DEBIAN_FRONTEND':'noninteractive'})
            code=p.returncode
        finally:
            after=inventory()
            if component in GROUPS:
                old=ledger['components'].get(component,{})
                added={p for p in after-before if GROUPS[component].fullmatch(p)}
                owned=old.get('owned') is True or (not preexisting and bool(added))
                previous=set(old.get('packages',[])) if old.get('owned') is True else set()
                ledger['components'][component]={'owned':owned,'preexisting':old.get('preexisting',preexisting),'packages':sorted(previous|added) if owned else []}
                save_ledger(ledger)
        return code

def remaining_instances():
    result=set()
    for n in range(1,100):
        suffix='' if n==1 else '-'+str(n)
        paths=[ROOT/('opt/psiphon-autopin'+suffix),ROOT/('opt/vps-psiphon'+suffix),
            ROOT/('var/lib/psiphon-autopin'+suffix),ROOT/('etc/systemd/system/psiphon-autopin'+suffix+'.service'),
            ROOT/('etc/systemd/system/vps-psiphon'+suffix+'.service')]
        if any(p.exists() for p in paths):result.add(n)
    return sorted(result)

def docker_unused():
    if not shutil.which('docker'):return False,'Docker usage cannot be checked'
    try:p=subprocess.run(['docker','ps','-aq'],capture_output=True,text=True,timeout=30)
    except (OSError,subprocess.TimeoutExpired):return False,'Docker usage cannot be checked'
    if p.returncode:return False,'Docker daemon unavailable; usage is unknown'
    if p.stdout.strip():return False,'Other running or stopped Docker containers exist'
    return True,''

def purge_plan(packages,owned):
    p=subprocess.run(['apt-get','-s','purge','--',*packages],capture_output=True,text=True,timeout=120)
    if p.returncode:return False,'APT simulation failed'
    removed={m.group(1).split(':',1)[0] for m in re.finditer(r'^(?:Remv|Purg)\s+([a-zA-Z0-9+.:_-]+)',p.stdout,re.M)}
    if not removed:return False,'APT did not produce a verifiable removal plan'
    if removed-set(owned):return False,'APT would remove packages outside the ownership receipt'
    return True,''

def cleanup_dependencies(purge=False,lock_held=False):
    """Never infer ownership from current binary presence or old Auto-Pin files."""
    result={}
    with (contextlib.nullcontext() if lock_held else locked()):
        ledger=load_ledger();others=remaining_instances()
        if others:return {'retained':'Other Auto-Pin instances still exist','instances':others}
        if not purge:
            # Explicit plain uninstall leaves dependencies as preexisting for a future install.
            save_ledger({'version':1,'components':{}})
            return {'retained':'Plain uninstall keeps dependencies'}
        installed=inventory()
        all_owned={p for r in ledger['components'].values() if r.get('owned') is True for p in r['packages']}
        for component in ('docker','go'):
            receipt=ledger['components'].get(component,{})
            if receipt.get('owned') is not True:
                result[component]={'retained':'Preexisting or no ownership receipt'};continue
            packages=sorted(set(receipt['packages'])&installed)
            if not packages:
                result[component]={'removed':[]};ledger['components'].pop(component,None);continue
            if component=='docker':
                unused,reason=docker_unused()
                if not unused:result[component]={'retained':reason};continue
            allowed,reason=purge_plan(packages,all_owned)
            if not allowed:result[component]={'retained':reason};continue
            p=subprocess.run(['apt-get','-y','purge','--',*packages],env={**os.environ,'DEBIAN_FRONTEND':'noninteractive'})
            now=inventory();left=sorted(set(packages)&now)
            result[component]={'removed':sorted(set(packages)-now),'remaining':left,'exit_code':p.returncode}
            if not left:ledger['components'].pop(component,None)
            installed=now
        save_ledger(ledger)
    return result

def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='command',required=True)
    p=sub.add_parser('install');p.add_argument('--lock-held',action='store_true',help=argparse.SUPPRESS);p.add_argument('component',choices=(*GROUPS,'tools'));p.add_argument('packages',nargs='+')
    p=sub.add_parser('cleanup');p.add_argument('--purge',action='store_true')
    args=parser.parse_args(argv)
    if os.geteuid()!=0:raise RuntimeError('Run as root')
    if args.command=='install':return install(args.component,args.packages,args.lock_held)
    print(json.dumps(cleanup_dependencies(args.purge),indent=2));return 0

if __name__=='__main__':raise SystemExit(main())
PY_SYSTEM
}
export DEBIAN_FRONTEND=noninteractive
ROOT=/opt/vps-psiphon; CONF="$ROOT/config"; APP=/opt/psiphon-autopin
DATA=/var/lib/psiphon-autopin; CONTAINER=vps-psiphon
CONNECTION=socks5; MENU_MODE=easy
INSTANCE=1; REGION_POOL=''; DENY_REGIONS='RU BY IR SY CU KP CN VE'; MIN_SPEED=800; SLOW_THRESHOLD=2; IMPERSONATE=0; TUNNEL_POOL=1; BIND=127.0.0.1; PUBLISH_HTTP=1
REGION=''; INTERVAL=300; WAIT=75; DELAY=12; SOCKS_PORT=''
YOUTUBE_MODE=0
GEMINI_CHECK=1; PROBE_MB=4; FAIL_THRESHOLD=3; STRICT_REGION=0
PORT_EXPLICIT=0; BACKEND=auto; REGION_EXPLICIT=0
declare -A POLICY_SET=()
while (($#)); do
    case "$1" in
        --youtube-mode) POLICY_SET[youtube_mode]=1; YOUTUBE_MODE=1; shift ;;
        --no-youtube-mode) POLICY_SET[youtube_mode]=1; YOUTUBE_MODE=0; shift ;;
        --connection) POLICY_SET[connection_type]=1; CONNECTION=${2:?Missing connection type}; shift 2 ;;
        --menu-mode) POLICY_SET[menu_mode]=1; MENU_MODE=${2:?Missing mode}; shift 2 ;;
        --bind) POLICY_SET[bind]=1; BIND=${2:?Missing address}; shift 2 ;;
        --bind-loopback) POLICY_SET[bind]=1; BIND=127.0.0.1; shift ;;
        --no-http) POLICY_SET[publish_http]=1; PUBLISH_HTTP=0; shift ;;
        --http) POLICY_SET[publish_http]=1; PUBLISH_HTTP=1; shift ;;
        --instance) INSTANCE=${2:?Missing instance}; shift 2 ;;
        --region-pool) POLICY_SET[region_pool]=1; REGION_POOL=${2:?Missing pool}; shift 2 ;;
        --deny-regions) POLICY_SET[deny_regions]=1; DENY_REGIONS=${2-}; shift 2 ;;
        --min-speed) POLICY_SET[min_speed_kib]=1; MIN_SPEED=${2:?Missing speed}; shift 2 ;;
        --slow-threshold) POLICY_SET[slow_threshold]=1; SLOW_THRESHOLD=${2:?Missing threshold}; shift 2 ;;
        --impersonate) POLICY_SET[impersonate]=1; IMPERSONATE=1; shift ;;
        --no-impersonate) POLICY_SET[impersonate]=1; IMPERSONATE=0; shift ;;
        --tunnel-pool) POLICY_SET[tunnel_pool]=1; TUNNEL_POOL=${2:?Missing size}; shift 2 ;;
        --region) REGION=${2:?Missing region}; REGION_EXPLICIT=1; shift 2 ;;
        --backend) BACKEND=${2:?Missing backend}; shift 2 ;;
        --port) SOCKS_PORT=${2:?Missing port}; PORT_EXPLICIT=1; shift 2 ;;
        --interval) POLICY_SET[interval]=1; INTERVAL=${2:?Missing interval}; shift 2 ;;
        --wait) POLICY_SET[wait]=1; WAIT=${2:?Missing wait}; shift 2 ;;
        --delay) POLICY_SET[delay]=1; DELAY=${2:?Missing delay}; shift 2 ;;
        --gemini-check) POLICY_SET[gemini_check]=1; GEMINI_CHECK=1; shift ;;
        --no-gemini-check) POLICY_SET[gemini_check]=1; GEMINI_CHECK=0; shift ;;
        --no-strict-region) POLICY_SET[strict_region]=1; STRICT_REGION=0; shift ;;
        --strict-region) POLICY_SET[strict_region]=1; STRICT_REGION=1; shift ;;
        --probe-mb) POLICY_SET[probe_mb]=1; PROBE_MB=${2:?Missing MB}; shift 2 ;;
        --fail-threshold) POLICY_SET[fail_threshold]=1; FAIL_THRESHOLD=${2:?Missing threshold}; shift 2 ;;
        --help) printf '%b\n' 'Interactive: install_psiphon_autopin.sh [--menu [--instance N]]; reopen: auto-pin.\nUsage: install_psiphon_autopin.sh [--youtube-mode|--no-youtube-mode] [--connection socks5|xray] [--bind 127.0.0.1] [--no-http] [--instance 1..99] [--region-pool NL,DE] [--min-speed 800] [--slow-threshold 2] [--deny-regions "RU BY IR SY CU KP CN VE"] [--impersonate] [--tunnel-pool 1..32] [--backend auto|console|vps-psiphon] [--region DE|AUTO] [--port 40000] [--interval 300] [--wait 75] [--delay 12] [--gemini-check] [--probe-mb 0..10] [--strict-region] [--fail-threshold 3]'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ $INSTANCE =~ ^[1-9][0-9]?$ ]] || { echo 'Instance must be 1..99' >&2; exit 2; }
SUFFIX=''; [[ $INSTANCE == 1 ]] || SUFFIX="-$INSTANCE"
CONTAINER="vps-psiphon$SUFFIX"; ROOT="/opt/$CONTAINER"; CONF="$ROOT/config"
APP="/opt/psiphon-autopin$SUFFIX"; DATA="/var/lib/psiphon-autopin$SUFFIX"
MONITOR="psiphon-autopin$SUFFIX.service"; ENVF="/etc/default/$CONTAINER"; RUNNER="/usr/local/sbin/$CONTAINER-run"
[[ $MIN_SPEED =~ ^[0-9]+$ && $SLOW_THRESHOLD =~ ^[0-9]+$ && $TUNNEL_POOL =~ ^[0-9]+$ ]] || exit 2
(( SLOW_THRESHOLD>=2 && SLOW_THRESHOLD<=20 && TUNNEL_POOL>=1 && TUNNEL_POOL<=32 )) || exit 2
# A comma-separated --region is a pool, too. AUTO remains unrestricted.
if [[ $REGION == *,* ]]; then POLICY_SET[region_pool]=1; REGION_POOL=$REGION; REGION=${REGION%%,*}; fi
if [[ -n $REGION_POOL ]]; then
    REGION_POOL=${REGION_POOL^^}; REGION_POOL=${REGION_POOL//,/ }
    for country in $REGION_POOL; do [[ $country =~ ^[A-Z]{2}$ ]] || { echo 'Invalid region pool' >&2; exit 2; }; done
    (( REGION_EXPLICIT )) || REGION=${REGION_POOL%% *}
    REGION_EXPLICIT=1
fi
if (( REGION_EXPLICIT )) && [[ -z ${POLICY_SET[region_pool]:-} ]]; then POLICY_SET[region_pool]=1; fi
DENY_REGIONS=${DENY_REGIONS^^}; DENY_REGIONS=${DENY_REGIONS//,/ }
for country in $DENY_REGIONS; do [[ $country =~ ^[A-Z]{2}$ ]] || { echo 'Invalid deny list' >&2; exit 2; }; done
# Reinstalls retain the installed region and host port unless explicitly changed.
[[ $BACKEND == auto || $BACKEND == console || $BACKEND == vps-psiphon ]] || { echo 'Invalid backend' >&2; exit 2; }
if [[ $BACKEND == auto ]]; then
    if [[ -f "$ENVF" && -x "$RUNNER" ]]; then
        BACKEND=vps-psiphon
    elif [[ -f $DATA/settings.json ]]; then
        BACKEND=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("backend","console"))' "$DATA/settings.json")
    elif docker inspect -f '{{.Config.Image}}' "$CONTAINER" 2>/dev/null | grep -Eqx 'local-psiphon-console:(latest|4\.3\.0)'; then
        BACKEND=console
    else
        BACKEND=vps-psiphon
    fi
fi
[[ $BACKEND == console || $BACKEND == vps-psiphon ]] || { echo 'Invalid saved backend' >&2; exit 2; }
if [[ -f $DATA/settings.json ]]; then
    if (( ! REGION_EXPLICIT )); then
        REGION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("region","") or "AUTO")' "$DATA/settings.json")
    fi
    if (( ! PORT_EXPLICIT )); then
        SOCKS_PORT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("port",40000))' "$DATA/settings.json")
    fi
elif [[ $BACKEND == vps-psiphon && -f "$ENVF" ]]; then
    # Parse values, never execute the foreign env file during discovery.
    if (( ! REGION_EXPLICIT )); then
        REGION=$(sed -n 's/^EGRESS_REGION=//p' "$ENVF" | head -1 | tr -d "\"'")
        REGION=${REGION:-AUTO}
    fi
    if (( ! PORT_EXPLICIT )); then
        SOCKS_PORT=$(sed -n 's/^SOCKS_PORT=//p' "$ENVF" | head -1 | tr -d "\"'")
        # The instruction's patched launcher can publish 40000:1080 while the
        # env file still says 1080. The actual published host port wins.
        published=$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$CONTAINER" 2>/dev/null || true)
        if [[ -n $published ]]; then
            actual_port=$(python3 - "$published" "$SOCKS_PORT" <<'HOST_PORT'
import json,sys
bindings=json.loads(sys.argv[1]) or {}
rows=bindings.get(f'{sys.argv[2]}/tcp') or bindings.get('1080/tcp') or []
ports={row.get('HostPort','') for row in rows}
print(ports.pop() if len(ports)==1 else '')
HOST_PORT
)
            [[ -z $actual_port ]] || SOCKS_PORT=$actual_port
        fi
    fi
fi
if [[ -f $DATA/settings.json ]]; then
    mapfile -t saved_policy < <(python3 - "$DATA/settings.json" <<'SAVED_POLICY'
import json,sys
s=json.load(open(sys.argv[1]))
for key,default in [('region_pool',[]),('deny_regions',['RU','BY','IR','SY','CU','KP','CN','VE']),('min_speed_kib',800),('slow_threshold',2),('tunnel_pool',1),('probe_mb',4),('interval',300),('wait',75),('delay',12),('fail_threshold',3),('impersonate',False),('gemini_check',True),('bind','127.0.0.1'),('publish_http',True),('strict_region',False),('connection_type','socks5'),('menu_mode','easy'),('youtube_mode',False)]:
    v=s.get(key,default)
    print(' '.join(v) if isinstance(v,list) else v if isinstance(v,str) else int(v))
SAVED_POLICY
)
    fields=(region_pool deny_regions min_speed_kib slow_threshold tunnel_pool probe_mb interval wait delay fail_threshold impersonate gemini_check bind publish_http strict_region connection_type menu_mode youtube_mode)
    variables=(REGION_POOL DENY_REGIONS MIN_SPEED SLOW_THRESHOLD TUNNEL_POOL PROBE_MB INTERVAL WAIT DELAY FAIL_THRESHOLD IMPERSONATE GEMINI_CHECK BIND PUBLISH_HTTP STRICT_REGION CONNECTION MENU_MODE YOUTUBE_MODE)
    for index in "${!fields[@]}"; do
        if [[ -z ${POLICY_SET[${fields[$index]}]:-} ]]; then printf -v "${variables[$index]}" '%s' "${saved_policy[$index]}"; fi
    done
fi
# New YouTube instances get a video floor; saved/explicit speeds are never replaced.
if (( YOUTUBE_MODE )) && [[ ! -f $DATA/settings.json && -z ${POLICY_SET[min_speed_kib]:-} ]]; then
    MIN_SPEED=1500
fi
if (( YOUTUBE_MODE )); then
    (( ! GEMINI_CHECK )) || { echo '[ERROR] YouTube and Gemini need separate instances. Use --no-gemini-check for YouTube and --instance N for Gemini.' >&2; exit 2; }
    (( TUNNEL_POOL == 1 )) || { echo '[ERROR] YouTube requires --tunnel-pool 1 for verified PIN.' >&2; exit 2; }
    [[ $BIND == 127.* ]] || { echo '[ERROR] YouTube requires loopback binding.' >&2; exit 2; }
fi
[[ $CONNECTION == socks5 || $CONNECTION == xray ]] || { echo 'Connection must be socks5 or xray' >&2; exit 2; }
[[ $MENU_MODE == easy || $MENU_MODE == advanced ]] || { echo 'Menu mode must be easy or advanced' >&2; exit 2; }
if [[ -e /usr/local/sbin/auto-pin ]] && ! grep -q '^# Managed by Forcus Auto-Pin menu$' /usr/local/sbin/auto-pin; then
    echo '[ERROR] /usr/local/sbin/auto-pin belongs to another program; no services changed.' >&2
    exit 1
fi
python3 - "$BIND" <<'BIND_VALIDATION'
import ipaddress,sys
p=ipaddress.ip_address(sys.argv[1])
if p.version!=4 or not any(p in ipaddress.ip_network(n) for n in ['127.0.0.0/8','10.0.0.0/8','172.16.0.0/12','192.168.0.0/16']):
    raise SystemExit('Bind must be loopback or a private IPv4 address')
BIND_VALIDATION
if [[ $BACKEND == console && $BIND != 127.0.0.1 ]]; then echo 'Private interface binding requires --backend vps-psiphon' >&2; exit 2; fi
if [[ -z $REGION ]]; then
    if [[ -r /dev/tty && -t 1 ]]; then
        read -r -p 'Psiphon country [DE] (or AUTO): ' REGION </dev/tty
        REGION=${REGION:-DE}
    else
        echo 'Noninteractive install: specify --region DE' >&2; exit 2
    fi
fi
# On interactive installs, ask for a SOCKS5 port, with Enter accepting 40000.
# The /dev/tty input works even with curl | sudo bash.
if [[ -z $SOCKS_PORT ]]; then
    if [[ -r /dev/tty && -t 1 ]]; then
        read -r -p "SOCKS5 port [$((40000+2*(INSTANCE-1)))]: " SOCKS_PORT </dev/tty
        SOCKS_PORT=${SOCKS_PORT:-$((40000+2*(INSTANCE-1)))}
    else
        SOCKS_PORT=$((40000+2*(INSTANCE-1)))
    fi
fi
[[ $SOCKS_PORT =~ ^[0-9]+$ ]] || { echo 'Port must be numeric' >&2; exit 2; }
SOCKS_PORT=$((10#$SOCKS_PORT))
(( SOCKS_PORT >= 1024 && SOCKS_PORT <= 65534 )) || {
    echo 'Choose SOCKS5 port 1024..65534 (HTTP uses port+1)' >&2; exit 2;
}
HTTP_PORT=$((SOCKS_PORT + 1))
REGION=${REGION^^}
[[ $REGION == AUTO || $REGION =~ ^[A-Z]{2}$ ]] || { echo 'Invalid country' >&2; exit 2; }
[[ $INTERVAL =~ ^[0-9]+$ && $WAIT =~ ^[0-9]+$ && $DELAY =~ ^[0-9]+$ ]] || exit 2
[[ $PROBE_MB =~ ^[0-9]+$ && $FAIL_THRESHOLD =~ ^[0-9]+$ ]] || { echo 'Invalid probe size or failure threshold' >&2; exit 2; }
(( PROBE_MB <= 10 && FAIL_THRESHOLD >= 2 && FAIL_THRESHOLD <= 20 )) || { echo 'Require --probe-mb 0..10, --fail-threshold 2..20' >&2; exit 2; }
(( INTERVAL >= 60 && WAIT >= 20 && DELAY >= 2 )) || { echo 'Require interval>=60, wait>=20, delay>=2' >&2; exit 2; }
[[ $REGION == AUTO ]] && REGION=''
# Serialize installation/removal of shared dependencies across all instances.
mkdir -p /var/lib/psiphon-autopin-system
chmod 700 /var/lib/psiphon-autopin-system
exec {AUTOPIN_TRANSACTION_LOCK_FD}>>/var/lib/psiphon-autopin-system/dependencies.lock
chmod 600 /var/lib/psiphon-autopin-system/dependencies.lock
flock -x "$AUTOPIN_TRANSACTION_LOCK_FD"
if [[ ${AUTOPIN_CREATE_ONLY:-0} == 1 && ( -e "$APP/psiphon_autopin.py" || -e "$DATA/settings.json" ) ]]; then
    echo "[ERROR] Instance $INSTANCE already exists; template creation will not overwrite it." >&2
    return 2
fi
python3 - "$INSTANCE" "$SOCKS_PORT" "$PUBLISH_HTTP" <<'PORT_RESERVATIONS'
from pathlib import Path
import json,sys
number,port,publish=map(int,sys.argv[1:]);wanted={port,port+1} if publish else {port}
for p in Path('/var/lib').glob('psiphon-autopin*/settings.json'):
    try:c=json.loads(p.read_text())
    except (OSError,ValueError):raise SystemExit('Cannot validate saved proxy ports: '+str(p))
    other=int(c.get('instance',1 if p.parent.name=='psiphon-autopin' else p.parent.name.rsplit('-',1)[-1]))
    if other==number:continue
    used={int(c.get('port',40000+2*(other-1)))}
    if c.get('publish_http',True):used.add(min(used)+1)
    if wanted&used:raise SystemExit(f'Proxy port reserved by instance {other}: {sorted(wanted&used)}')
PORT_RESERVATIONS
mkdir -p "$ROOT" "$CONF" "$APP" "$DATA"
chmod 700 "$DATA"
echo "[INFO] Region=${REGION:-AUTO}; SOCKS5=127.0.0.1:$SOCKS_PORT; manager v4.4.0; backend=$BACKEND"

# Monitor is stopped after installation ownership checks below.

# Private receipt helper is available before Docker/Go package installation.
dep_tmp=$(mktemp -d)
write_system_module > "$dep_tmp/autopin_system.py"
trap '[[ -z ${dep_tmp:-} ]] || rm -rf "$dep_tmp"' EXIT
# Install only missing packages. Never replace Docker CE with Ubuntu docker.io.
GO_MISSING=0
PACKAGES=()
command -v curl >/dev/null 2>&1 || PACKAGES+=(curl)
command -v jq >/dev/null 2>&1 || PACKAGES+=(jq)
command -v python3 >/dev/null 2>&1 || PACKAGES+=(python3)
command -v column >/dev/null 2>&1 || PACKAGES+=(bsdextrautils)
command -v go >/dev/null 2>&1 || { PACKAGES+=(golang-go); GO_MISSING=1; }
command -v ss >/dev/null 2>&1 || PACKAGES+=(iproute2)
if ((${#PACKAGES[@]})); then
    apt-get update
    if (( GO_MISSING )); then
        python3 "$dep_tmp/autopin_system.py" install --lock-held go ca-certificates "${PACKAGES[@]}"
    else
        apt-get install -y ca-certificates "${PACKAGES[@]}"
    fi
fi
if ! command -v docker >/dev/null 2>&1; then
    apt-get update
    if apt-cache show docker-ce 2>/dev/null | grep -q '^Package: docker-ce$'; then
        python3 "$dep_tmp/autopin_system.py" install --lock-held docker docker-ce docker-ce-cli containerd.io
    else
        python3 "$dep_tmp/autopin_system.py" install --lock-held docker docker.io
    fi
else
    echo "[OK] Using existing $(docker --version)"
fi
systemctl enable --now docker
if ! docker info >/dev/null 2>&1; then
    echo '[ERROR] Docker daemon not responding' >&2; exit 1
fi

# Refuse an obsolete compiler before stopping a working instance. Existing Go is never replaced.
GO_VERSION_TEXT=$(GOTOOLCHAIN=local go version)
python3 - "$GO_VERSION_TEXT" <<'GO_VERSION_CHECK'
import re,sys
found=re.search(r'go([0-9]+)\.([0-9]+)',sys.argv[1])
if not found or tuple(map(int,found.groups()))<(1,21):
    raise SystemExit('Go 1.21+ is required (exporter dependency needs Go 1.22; Go 1.21+ may select a checksum-verified toolchain). Existing Go and services were not replaced.')
GO_VERSION_CHECK

# Check both listeners when creating a container or changing its ports.
port_occupied() {
    ss -ltnH | awk '{print $4}' | grep -Eq "(^|:)$1$"
}

proxy_port_occupied() {
    port_occupied "$SOCKS_PORT" || { (( PUBLISH_HTTP )) && port_occupied "$HTTP_PORT"; }
}
# vps-psiphon is systemd-owned and uses --rm: its container can be absent
# between starts. Recognize the installation by BOTH launcher and env file.
if [[ $BACKEND == vps-psiphon ]]; then
    LEGACY=0
    if [[ -f "$ENVF" && -x "$RUNNER" ]] && systemctl cat "$CONTAINER.service" >/dev/null 2>&1; then
        LEGACY=1
    elif [[ -e $CONF/psiphon.config ]] || docker container inspect "$CONTAINER" >/dev/null 2>&1; then
        echo '[ERROR] Existing Psiphon is not a recognized vps-psiphon installation; use --backend console for an existing Auto-Pin console container.' >&2
        exit 1
    fi
    # Reject name/mount/image overrides before changing any running services.
    if (( LEGACY )); then
        python3 - "$ENVF" "$CONTAINER" "$CONF" "$PIN_IMAGE" <<'VALIDATE_VPS'
import shlex,sys
values={}
for line in open(sys.argv[1]):
    if '=' in line and not line.lstrip().startswith('#'):
        key,value=line.rstrip().split('=',1)
        parts=shlex.split(value,comments=True)
        values[key]=' '.join(parts)
if values.get('IMAGE','swarupsengupta2007/psiphon:latest') not in ('swarupsengupta2007/psiphon:latest',sys.argv[4]):raise SystemExit('Unsupported vps-psiphon IMAGE; no services changed')
for key,want in {'NAME':sys.argv[2],'CONF_DIR':sys.argv[3]}.items():
    if values.get(key,want)!=want:raise SystemExit(f'Unsupported vps-psiphon {key}; no services changed')
VALIDATE_VPS
        if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
            CURRENT_IMAGE=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER")
            [[ ( $CURRENT_IMAGE == swarupsengupta2007/psiphon:latest || $CURRENT_IMAGE == "$PIN_IMAGE" ) &&
               $(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}' "$CONTAINER") == "$CONF" ]] || {
                echo '[ERROR] Foreign vps-psiphon container; no services changed.' >&2; exit 1;
            }
        fi
    fi
    docker pull "$PIN_IMAGE"
    systemctl stop "$MONITOR" 2>/dev/null || true
    # Only Auto-Pin may rotate this tunnel: disable the independent watchdog.
    systemctl disable --now "$CONTAINER-watchdog.timer" "$CONTAINER-watchdog.service" 2>/dev/null || true
    if (( LEGACY )); then systemctl stop "$CONTAINER.service"; fi
    # Back up the stopped datastore and all files changed by the migration.
    mkdir -p "/var/backups/psiphon-autopin/$CONTAINER"; chmod 700 /var/backups/psiphon-autopin
    BACKUP="/var/backups/psiphon-autopin/$CONTAINER/backup-$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -m 700 "$BACKUP"
    cp -a "$CONF" "$BACKUP/config"
    for f in "$ENVF" "$RUNNER" "$DATA/settings.json" "$DATA/state.json" "$DATA/server-entry-cache.json"; do
        [[ ! -f $f ]] || cp -a "$f" "$BACKUP/"
    done
    systemctl cat "$CONTAINER.service" > "$BACKUP/$CONTAINER.service" 2>/dev/null || true
    echo "[INFO] Migration backup: $BACKUP"
    if (( ! LEGACY )); then
        ports=("$SOCKS_PORT"); (( ! PUBLISH_HTTP )) || ports+=("$HTTP_PORT")
        for port in "${ports[@]}"; do
            if port_occupied "$port"; then echo "[ERROR] Proxy port $port occupied" >&2; exit 1; fi
        done
        docker pull "$PIN_IMAGE"
        docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges:true --entrypoint cat "$PIN_IMAGE" /etc/psiphon/psiphon.config > "$CONF/psiphon.config"
        chown 1000:1000 "$CONF/psiphon.config"; chmod 600 "$CONF/psiphon.config"
        cat > "$ENVF" <<EOF
IMAGE=$PIN_IMAGE
NAME=$CONTAINER
CONF_DIR=$CONF
DEVICE_REGION=
EOF
    fi
    if (( LEGACY )); then systemctl stop "$CONTAINER.service"; fi
    if proxy_port_occupied; then
        echo "[ERROR] SOCKS/HTTP port $SOCKS_PORT/$HTTP_PORT occupied; original files are in $BACKUP" >&2
        systemctl daemon-reload
        systemctl start "$CONTAINER.service"
        exit 1
    fi
    # Keep host ports separate from container ports; do not patch upstream with sed.
    python3 - "$ENVF" "$REGION" "$SOCKS_PORT" "$HTTP_PORT" "$CONTAINER" "$CONF" "$TUNNEL_POOL" "$BIND" "$PUBLISH_HTTP" "$PIN_IMAGE" <<'VPS_ENV'
from pathlib import Path
import sys
p=Path(sys.argv[1]);region,socks,http,name,conf,pool,bind,publish,image=sys.argv[2:]
updates={'NAME':name,'CONF_DIR':conf,
         'IMAGE':image,
         'BIND':bind,'SOCKS_PORT':socks,'HTTP_PORT':http,
         'PUBLISH_HTTP':publish,'EGRESS_REGION':region,'TUNNEL_POOL_SIZE':pool,
         'REGION_POOL':"''"}
lines=p.read_text().splitlines()
lines=[line for line in lines if line.split('=',1)[0] not in updates]
p.write_text('\n'.join(lines+[f'{k}={v}' for k,v in updates.items()])+'\n')
VPS_ENV
    sed -e "s/@P@/$CONTAINER/g" -e "s|@IMAGE@|$PIN_IMAGE|g" > "$RUNNER" <<'VPS_RUN'
#!/usr/bin/env bash
# Managed by Forcus Auto-Pin. Host ports in env; fixed ports inside Docker.
set -euo pipefail
. /etc/default/@P@
[[ $IMAGE == '@IMAGE@' ]] || { echo 'Unpinned Psiphon image rejected' >&2; exit 1; }
python3 - "$BIND" <<'RUNTIME_BIND'
import ipaddress,sys
p=ipaddress.ip_address(sys.argv[1])
assert p.version==4 and any(p in ipaddress.ip_network(n) for n in ['127.0.0.0/8','10.0.0.0/8','172.16.0.0/12','192.168.0.0/16']), 'Unsafe bind address'
RUNTIME_BIND
python3 - "$CONF_DIR/psiphon.config" "${EGRESS_REGION:-}" "${TUNNEL_POOL_SIZE:-1}" <<'VPS_CONFIG'
import json,os,sys,tempfile
p,region,pool=sys.argv[1:];st=os.stat(p)
with open(p) as f:c=json.load(f)
c.update(EgressRegion=region,ListenInterface='any',LocalSocksProxyPort=1080,
         LocalHttpProxyPort=8080,TunnelPoolSize=int(pool),EmitDiagnosticNotices=True,DisableReplay=True,
         DisableTactics=True,LimitTunnelProtocols=['SSH','OSSH','QUIC-OSSH','TLS-OSSH',
         'SHADOWSOCKS-OSSH','UNFRONTED-MEEK-OSSH','UNFRONTED-MEEK-HTTPS-OSSH',
         'UNFRONTED-MEEK-SESSION-TICKET-OSSH','FRONTED-MEEK-OSSH','FRONTED-MEEK-HTTP-OSSH'])
c.pop('LocalSocksProxyListenAddress',None);c.pop('LocalHttpProxyListenAddress',None)
with tempfile.NamedTemporaryFile('w',dir=os.path.dirname(p),delete=False) as f:
    json.dump(c,f,indent=2);f.write('\n');name=f.name
os.chown(name,st.st_uid,st.st_gid);os.chmod(name,st.st_mode & 0o777)
os.replace(name,p)
VPS_CONFIG
docker rm -f "$NAME" >/dev/null 2>&1 || true
ports=(-p "${BIND}:${SOCKS_PORT}:1080")
if [[ ${PUBLISH_HTTP:-1} == 1 ]]; then ports+=(-p "${BIND}:${HTTP_PORT}:8080"); fi
chown -R 1000:1000 "$CONF_DIR"
exec docker run --rm --name "$NAME" --user 1000:1000 --workdir /config \
    --read-only --tmpfs /tmp:rw,noexec,nosuid,size=32m --cap-drop ALL --security-opt no-new-privileges:true --pids-limit 256 \
    --entrypoint /usr/local/bin/psiphon \
    "${ports[@]}" \
    -e PUID=1000 -e PGID=1000 -e SOCKS_PORT=1080 -e HTTP_PORT=8080 \
    -e DEVICE_REGION="${DEVICE_REGION:-}" -e EGRESS_REGION="${EGRESS_REGION:-}" \
    -v "${CONF_DIR}:/config" "$IMAGE" -config /config/psiphon.config
VPS_RUN
    chmod 755 "$RUNNER"
    if [[ ! -s $CONF/psiphon.config ]]; then
        docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges:true --entrypoint cat "$PIN_IMAGE" /etc/psiphon/psiphon.config > "$CONF/psiphon.config"
        chown 1000:1000 "$CONF/psiphon.config"
        chmod 600 "$CONF/psiphon.config"
    fi
    # Clear previous target only when the requested region actually changes.
    python3 - "$CONF/psiphon.config" "$DATA/state.json" "$REGION" <<'VPS_REGION'
import json,sys
from pathlib import Path
p,s,r=sys.argv[1:]
c=json.loads(Path(p).read_text())
if c.get('EgressRegion','')!=r:
    c.pop('TargetServerEntry',None)
    Path(s).unlink(missing_ok=True)
    (Path(s).parent/'server-entry-cache.json').unlink(missing_ok=True)
c.update(EgressRegion=r,EmitDiagnosticNotices=True,TunnelPoolSize=1)
Path(p).write_text(json.dumps(c,indent=2)+'\n')
VPS_REGION
    cat > "/etc/systemd/system/$CONTAINER.service" <<EOF
[Unit]
Description=Forcus Psiphon tunnel $INSTANCE
After=docker.service network-online.target
Requires=docker.service
PartOf=docker.service
[Service]
ExecStart=$RUNNER
ExecStop=/usr/bin/docker stop -t 10 $CONTAINER
Restart=always
RestartSec=10
TimeoutStartSec=0
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
RestrictNamespaces=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
CapabilityBoundingSet=CAP_CHOWN CAP_DAC_OVERRIDE CAP_FOWNER
ReadWritePaths=$CONF
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$CONTAINER.service"
    systemctl start "$CONTAINER.service"
else
CONSOLE_EXISTS=0
if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    IMAGE=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER")
    NETMODE=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER")
    MOUNT_OK=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}' "$CONTAINER")
    [[ ( $IMAGE == local-psiphon-console:latest || $IMAGE == local-psiphon-console:4.4.0 ) && $NETMODE == host && $MOUNT_OK == "$CONF" ]] || {
        echo '[ERROR] Existing container is not our console backend; no services changed.' >&2; exit 1;
    }
    [[ -f $CONF/psiphon.config ]] || { echo 'Missing console config' >&2; exit 1; }
    CONSOLE_EXISTS=1
else
    [[ ! -e $CONF/psiphon.config ]] || { echo 'Config exists but container missing; refusing overwrite.' >&2; exit 1; }
    if proxy_port_occupied; then echo 'Proxy port occupied' >&2; exit 1; fi
    docker pull "$PIN_IMAGE"
    docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges:true --entrypoint cat "$PIN_IMAGE" /etc/psiphon/psiphon.config > "$CONF/psiphon.config"
fi
# Verify before chmod, Docker COPY, or stopping a working container. No branch-name fallback.
console_tmp=$(mktemp "$ROOT/.console.XXXXXX")
curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error --retry 3 --max-time 180 \
    "https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/$CONSOLE_COMMIT/linux/psiphon-tunnel-core-x86_64" -o "$console_tmp"
if ! printf '%s  %s\n' "$CONSOLE_SHA256" "$console_tmp" | sha256sum --check --status; then
    rm -f "$console_tmp"; echo '[SECURITY ERROR] ConsoleClient SHA-256 mismatch; not executed.' >&2; exit 1
fi
chmod 755 "$console_tmp";mv -f "$console_tmp" "$ROOT/ConsoleClient"
cat > "$ROOT/Dockerfile" <<DOCKERFILE
FROM $CONSOLE_BASE
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY ConsoleClient /usr/local/bin/ConsoleClient
USER 1000:1000
WORKDIR /config
CMD ["/usr/local/bin/ConsoleClient", "-config", "/config/psiphon.config", "-dataRootDirectory", "/config"]
DOCKERFILE
# Do not send the private datastore/configuration into the Docker build context.
cat > "$ROOT/.dockerignore" <<'DOCKER_IGNORE'
**
!Dockerfile
!ConsoleClient
DOCKER_IGNORE
docker build -t local-psiphon-console:4.4.0 "$ROOT"
if (( CONSOLE_EXISTS )); then
    OLD_PORT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("LocalSocksProxyPort"))' "$CONF/psiphon.config")
    if [[ $OLD_PORT != "$SOCKS_PORT" ]] && proxy_port_occupied; then echo 'New proxy port occupied' >&2; exit 1; fi
fi
systemctl stop "$MONITOR" 2>/dev/null || true
if (( CONSOLE_EXISTS )); then docker stop "$CONTAINER" >/dev/null; fi
python3 - "$CONF/psiphon.config" "$DATA/state.json" "$REGION" "$SOCKS_PORT" "$HTTP_PORT" "$PUBLISH_HTTP" <<'CONSOLE_CONFIG'
import json,sys
from pathlib import Path
p,state,region,socks,http,publish=sys.argv[1:];c=json.loads(Path(p).read_text())
if c.get('EgressRegion','')!=region:
    c.pop('TargetServerEntry',None);Path(state).unlink(missing_ok=True)
c.update(EgressRegion=region,ListenInterface='lo',LocalSocksProxyPort=int(socks),LocalHttpProxyPort=int(http),DisableLocalHTTPProxy=publish=='0',EmitDiagnosticNotices=True,DisableReplay=True)
c.pop('LocalSocksProxyListenAddress',None);c.pop('LocalHttpProxyListenAddress',None)
Path(p).write_text(json.dumps(c,indent=2)+'\n')
CONSOLE_CONFIG
chown -R 1000:1000 "$CONF"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" --restart unless-stopped --network host --user 1000:1000 \
    --read-only --tmpfs /tmp:rw,noexec,nosuid,size=32m --cap-drop ALL --security-opt no-new-privileges:true --pids-limit 256 \
    -v "$CONF:/config" local-psiphon-console:4.4.0 >/dev/null
fi # console backend

python3 - "$DATA/settings.json" "$CONF/psiphon.config" "$DATA/state.json" "$YOUTUBE_MODE" <<'MODE_CHANGE'
import json,sys
from pathlib import Path
p,c,state=map(Path,sys.argv[1:4]);enabled=sys.argv[4]
old=json.loads(p.read_text()) if p.exists() else {}
if bool(old.get('youtube_mode',False))!=bool(int(enabled)):
    cfg=json.loads(c.read_text());cfg['TargetServerEntry']='';c.write_text(json.dumps(cfg,indent=2)+'\n')
    state.unlink(missing_ok=True)
    (p.parent/'youtube-status.json').unlink(missing_ok=True)
    (p.parent/'initial-pin-attempt.json').unlink(missing_ok=True)
    (p.parent/'mode-restart-required').touch()
MODE_CHANGE
POOL_CHANGED=$(python3 - "$CONF/psiphon.config" "$DATA/state.json" "$TUNNEL_POOL" <<'POOL_CONFIG'
import json,sys
from pathlib import Path
p,state,pool=sys.argv[1:];pool=int(pool);c=json.loads(Path(p).read_text())
if c.get('TunnelPoolSize',1)!=pool or (pool>1 and c.get('TargetServerEntry')):
    c['TunnelPoolSize']=pool;c.pop('TargetServerEntry',None)
    Path(state).unlink(missing_ok=True)
    Path(p).write_text(json.dumps(c,indent=2)+'\n');print('changed')
POOL_CONFIG
)
if [[ -n $POOL_CHANGED || -f $DATA/mode-restart-required ]]; then
    rm -f "$DATA/mode-restart-required"
    if [[ $BACKEND == vps-psiphon ]]; then systemctl restart "$CONTAINER.service"; else docker restart "$CONTAINER" >/dev/null; fi
fi

if [[ $BACKEND == console ]]; then
    HTTP_CHANGED=$(python3 - "$CONF/psiphon.config" "$PUBLISH_HTTP" <<'HTTP_POLICY'
import json,sys
p,enabled=sys.argv[1:];c=json.load(open(p));disabled=not bool(int(enabled))
if c.get('DisableLocalHTTPProxy',False)!=disabled:
    c['DisableLocalHTTPProxy']=disabled
    with open(p,'w') as f:json.dump(c,f,indent=2);f.write('\n')
    print('changed')
HTTP_POLICY
)
    if [[ -n $HTTP_CHANGED ]]; then docker restart "$CONTAINER" >/dev/null; fi
fi
# Fail closed: ConsoleClient must not expose either unauthenticated proxy on a public interface.
# This includes configurations inherited from a previously installed Psiphon container.
# Inspect actual listening sockets, not just the JSON file.
vps_mapping_ok() {
    docker inspect -f '{{json .HostConfig.PortBindings}}' "$CONTAINER" 2>/dev/null | python3 -c '
import json,sys
try:
    ports=json.load(sys.stdin)
    expected={"1080/tcp":[{"HostIp":sys.argv[3],"HostPort":sys.argv[1]}],
              "8080/tcp":[{"HostIp":sys.argv[3],"HostPort":sys.argv[2]}]}
    if sys.argv[4]=="0":expected.pop("8080/tcp")
    sys.exit(0 if ports==expected else 1)
except (ValueError,TypeError):sys.exit(1)
' "$SOCKS_PORT" "$HTTP_PORT" "${BIND:-127.0.0.1}" "${PUBLISH_HTTP:-1}"
}
proxy_listeners_ready() {
    if [[ $BACKEND == vps-psiphon ]]; then
        vps_mapping_ok
    else
        ss -H -ltn | awk -v enabled="$PUBLISH_HTTP" -v socks=":$SOCKS_PORT" -v http=":$HTTP_PORT" '
            $4 ~ socks "$" { a=1 } $4 ~ http "$" { b=1 } END { exit !(a && (b || !enabled)) }
        '
    fi
}
verify_proxy_binding() {
    local bad
    if [[ $BACKEND == vps-psiphon ]] && docker container inspect "$CONTAINER" >/dev/null 2>&1 && ! vps_mapping_ok; then
        echo '[SECURITY ERROR] Unexpected Docker port mappings; stopping vps-psiphon.' >&2
        systemctl stop "$CONTAINER.service"
        exit 1
    fi
    bad=$(ss -H -ltnp | awk -v bind="$BIND" -v enabled="$PUBLISH_HTTP" -v socks=":$SOCKS_PORT" -v http=":$HTTP_PORT" '
        {
          addr=$4
          if (addr ~ socks "$" || (enabled && addr ~ http "$")) {
            # Safe: IPv4 loopback, IPv6 loopback. All other bind addresses fail closed.
            if (addr != bind socks && addr != bind http) print $0
          }
        }')
    if [[ -n $bad ]]; then
        echo "[SECURITY ERROR] Psiphon proxy is listening outside configured address $BIND:" >&2
        echo "$bad" >&2
        echo '[SECURITY ERROR] Stopping Psiphon to prevent exposure.' >&2
        if [[ $BACKEND == vps-psiphon ]]; then systemctl stop "$CONTAINER.service"; else docker stop "$CONTAINER" >/dev/null || true; fi
        exit 1
    fi
}
verify_proxy_binding


# Recover bootstrap fields if an existing installation does not respond through SOCKS5.
# Check ONLY through the proxy. A failure must never fall back to a direct IP probe.
if ! curl -4 -fsS --max-time 15 --noproxy '' --proxy socks5h://127.0.0.1:${SOCKS_PORT} https://api.ipify.org >/dev/null 2>&1; then
    echo '[INFO] Checking bootstrap fields (SOCKS5 not yet responding)...'
    docker pull "$PIN_IMAGE"
    template=$(mktemp)
    docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges:true --entrypoint cat "$PIN_IMAGE" /etc/psiphon/psiphon.config > "$template"
    BOOTSTRAP_CHANGED=$(python3 - "$CONF/psiphon.config" "$template" <<'BOOTSTRAP'
import json,sys,shutil,datetime
p,t=sys.argv[1:]; a=json.load(open(p)); b=json.load(open(t))
keys=('RemoteServerListURLs','RemoteServerListSignaturePublicKey','ObfuscatedServerListRootURLs','ObfuscatedServerListSignaturePublicKey','ServerEntrySignaturePublicKey','SponsorId','PropagationChannelId')
missing=[k for k in keys if not a.get(k) and b.get(k)]
if missing:
    shutil.copy2(p,p+'.bootstrap-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
    for k in missing:a[k]=b[k]
    with open(p,'w') as f:json.dump(a,f,indent=2);f.write('\n')
print(','.join(missing))
BOOTSTRAP
)
    rm -f "$template"
    if [[ -n $BOOTSTRAP_CHANGED ]]; then
        echo "[INFO] Bootstrap fields added: $BOOTSTRAP_CHANGED"
        if [[ $BACKEND == vps-psiphon ]]; then systemctl restart "$CONTAINER.service"; else docker restart "$CONTAINER" >/dev/null; fi
    else
        echo '[INFO] Bootstrap complete; preserving the starting tunnel without another restart.'
    fi
fi

if (( IMPERSONATE )) && { [[ ! -x $APP/curl-impersonate/curl-impersonate ]] || [[ ! -f $APP/curl-impersonate/.verified-release ]] || [[ $(cat "$APP/curl-impersonate/.verified-release") != bc9bd2522fe1850dd54c0fff189c8dd606df3f222ab2a905f2dd255123c3f495 ]]; }; then
    ci_tmp=$(mktemp -d)
    # The current installer targets Debian/Ubuntu x86_64; the checksum belongs to the upstream release asset.
    curl -fLsS --retry 3 --max-time 300 https://github.com/lexiforest/curl-impersonate/releases/download/v2.3.2/curl-impersonate-v2.3.2.x86_64-linux-gnu.tar.gz -o "$ci_tmp/ci.tar.gz"
    echo "bc9bd2522fe1850dd54c0fff189c8dd606df3f222ab2a905f2dd255123c3f495  $ci_tmp/ci.tar.gz" | sha256sum -c -
    mkdir -p "$APP/curl-impersonate"
    tar -xzf "$ci_tmp/ci.tar.gz" -C "$APP/curl-impersonate"
    "$APP/curl-impersonate/curl-impersonate" --version >/dev/null
    echo bc9bd2522fe1850dd54c0fff189c8dd606df3f222ab2a905f2dd255123c3f495 > "$APP/curl-impersonate/.verified-release"
    rm -rf "$ci_tmp"
fi

cat > "$APP/psiphon-server-export.go" <<'GO_EXPORTER'
package main

import (
    "encoding/hex"
    "encoding/json"
    "fmt"
    "net"
    "os"
    "sort"
    "strings"
    "time"
    bolt "go.etcd.io/bbolt"
)

type Entry struct {
    Tag string `json:"tag"`
    IP string `json:"ipAddress"`
    Region string `json:"region"`
    Port string `json:"webServerPort"`
    Secret string `json:"webServerSecret"`
    Cert string `json:"webServerCertificate"`
    Capabilities []string `json:"capabilities"`
    Version int `json:"configurationVersion"`
}
type Candidate struct {
    ServerIP string `json:"server_ip"`
    Region string `json:"region"`
    Diagnostic string `json:"diagnostic"`
    Encoded string `json:"encoded"`
    Version int `json:"-"`
}
func main() {
    if len(os.Args)!=3 { fmt.Fprintln(os.Stderr,"usage: exporter DATABASE REGION");os.Exit(2) }
    db,err:=bolt.Open(os.Args[1],0400,&bolt.Options{ReadOnly:true,Timeout:5*time.Second})
    if err!=nil {panic(err)}
    defer db.Close()
    found:=make(map[string]Candidate)
    err=db.View(func(tx *bolt.Tx) error {
        var walk func(*bolt.Bucket) error
        walk=func(b *bolt.Bucket) error {
            return b.ForEach(func(k,v []byte) error {
                if v==nil {child:=b.Bucket(k);if child!=nil{return walk(child)};return nil}
                var e Entry
                if json.Unmarshal(v,&e)!=nil{return nil}
                if net.ParseIP(e.IP)==nil || len(e.Tag)<8 || len(e.Capabilities)==0 || (os.Args[2]!="" && e.Region!=os.Args[2]) {return nil}
                fields:=[]string{"0","0","0","0"}
                if e.Cert!="" {fields=[]string{e.IP,e.Port,e.Secret,e.Cert}}
                // JSON bytes originate in Psiphon's datastore. No credentials are printed.
                enc:=hex.EncodeToString([]byte(strings.Join(fields," ")+" "+string(v)))
                candidate:=Candidate{ServerIP:e.IP,Region:e.Region,Diagnostic:e.Tag[:8],Encoded:enc,Version:e.Version}
                if old,exists:=found[e.IP];!exists || e.Version>old.Version {found[e.IP]=candidate}
                return nil
            })
        }
        return tx.ForEach(func(_ []byte,b *bolt.Bucket) error{return walk(b)})
    })
    if err!=nil {panic(err)}
    keys:=make([]string,0,len(found))
    for ip:=range found {keys=append(keys,ip)}
    sort.Strings(keys)
    for _,ip:=range keys {b,_:=json.Marshal(found[ip]);fmt.Println(string(b))}
}
GO_EXPORTER

# Build the exporter only when its source changes.
if [[ ! -x "$APP/psiphon-server-export" || "$APP/psiphon-server-export.go" -nt "$APP/psiphon-server-export" ]]; then
    builddir=$(mktemp -d)
    cp "$APP/psiphon-server-export.go" "$builddir/main.go"
    ( export GOSUMDB=sum.golang.org GOPROXY=https://proxy.golang.org GONOSUMDB= GOPRIVATE= GOTOOLCHAIN=auto; cd "$builddir" && go mod init foc.us/psiphon-exporter >/dev/null && go get go.etcd.io/bbolt@v1.3.11 && go build -o "$APP/psiphon-server-export" . )
    rm -rf "$builddir"
    chmod 700 "$APP/psiphon-server-export"
fi

# A conservative, anonymous Gemini availability check through the pinned SOCKS5h exit.
# Only an explicit error 1060 is REFUSED. Changed web internals/errors => INCONCLUSIVE.
# There is no direct-connect fallback. Test request is deliberately low-volume.
cat > "$APP/gemini_probe.py" <<'PY_GEMINI'
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
        # A plain curl request can be redirected to Google CAPTCHA too.
        # Classify that explicit response before checking application session fields.
        if headers.exists():
            for line in headers.read_text(errors='replace').splitlines():
                if line.lower().startswith('location:'):
                    u=urlsplit(line.split(':',1)[1].strip())
                    if re.fullmatch(r'(?:[a-z0-9-]+\.)*google\.[a-z.]+',u.hostname or '') and u.path.startswith('/sorry'):
                        return 'CAPTCHA','request redirected to Google CAPTCHA'
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
PY_GEMINI
chmod 700 "$APP/gemini_probe.py"
python3 -m py_compile "$APP/gemini_probe.py"

cat > "$APP/psiphon_autopin.py" <<'PY_MANAGER'
#!/usr/bin/env python3
"""Forcus Psiphon Auto-Pin v4.4.0: controlled server selection + SOCKS-only geolocation."""
import argparse
import contextlib
import datetime as dt
import fcntl
import ipaddress
import json
import math
import os
from pathlib import Path
import random
import re
import shutil
import shlex
import subprocess
import sys
import tempfile
import time

BASE=Path('/opt/psiphon-autopin')
DATA=Path('/var/lib/psiphon-autopin')
CONFIG=Path('/opt/vps-psiphon/config/psiphon.config')
CONTAINER='vps-psiphon'
PROXY='127.0.0.1:40000'  # Updated from settings / --port in main()
STATE=DATA/'state.json'
ENV_FILE=Path('/etc/default/vps-psiphon')
INSTANCE=1
POLICY={}

def activity_report(status,detail='',**values):
    """Public progress only; never include encoded server credentials."""
    atomic_json(DATA/'activity.json',{'status':status,'detail':detail,
        'checked_at':dt.datetime.now(dt.timezone.utc).isoformat(),**values})

def view_instances():
    result=[]
    for path in DATA.parent.glob('psiphon-autopin*/settings.json'):
        suffix=path.parent.name.removeprefix('psiphon-autopin')
        if suffix and not re.fullmatch(r'-[2-9]|-[1-9][0-9]',suffix):continue
        number=int(suffix[1:]) if suffix else 1
        result.append(number)
    return sorted(set(result))

def view_config(number):
    suffix='' if number==1 else '-'+str(number)
    config=read_json(DATA.parent/('psiphon-autopin'+suffix)/'settings.json',{}) or {}
    name='YouTube' if config.get('youtube_mode') else 'Gemini' if config.get('gemini_check') else 'Psiphon'
    # settings contain user policy, not TargetServerEntry or datastore credentials.
    return {'instance':number,'name':name,'settings':config}

def all_views(args,targets):
    results=[];failed=False
    for number in targets:
        named=view_config(number)
        if args.command=='config':results.append(named);continue
        command=[sys.executable,str(Path(__file__)),args.command]
        if args.value is not None:command.append(args.value)
        command+=['--instance',str(number)]
        try:p=subprocess.run(command,capture_output=True,text=True,timeout=60)
        except (OSError,subprocess.SubprocessError) as exc:p=subprocess.CompletedProcess(command,1,stdout='',stderr=str(exc))
        failed=failed or bool(p.returncode)
        if args.command in ('status','xray'):
            try:value=json.loads(p.stdout)
            except ValueError:value={'error':(p.stderr or p.stdout)[-500:]}
            results.append({'instance':number,'name':named['name'],'result':value,'exit_code':p.returncode})
        else:
            print(f'===== Экземпляр {number} — {named["name"]} =====',flush=True)
            print(p.stdout,end='',flush=True)
            if p.stderr:print(p.stderr,file=sys.stderr,end='',flush=True)
    if args.command in ('status','xray','config'):print(json.dumps(results,ensure_ascii=False,indent=2))
    return 1 if failed else 0

def configure_instance(number):
    global INSTANCE,BASE,DATA,CONFIG,CONTAINER,STATE,CACHE,ENV_FILE,PROXY
    if not 1<=number<=99:raise ValueError('instance must be 1..99')
    INSTANCE=number
    suffix='' if number==1 else f'-{number}'
    BASE=Path('/opt/psiphon-autopin'+suffix)
    DATA=Path('/var/lib/psiphon-autopin'+suffix)
    CONTAINER='vps-psiphon'+suffix
    CONFIG=Path('/opt')/CONTAINER/'config/psiphon.config'
    STATE=DATA/'state.json';CACHE=DATA/'server-entry-cache.json'
    ENV_FILE=Path('/etc/default')/CONTAINER
    PROXY=f'127.0.0.1:{40000+2*(number-1)}'

def monitor_unit():
    return 'psiphon-autopin'+('' if INSTANCE==1 else f'-{INSTANCE}')+'.service'

def countries(value):
    rows=value.replace(',',' ').upper().split() if isinstance(value,str) else list(value or [])
    if any(not re.fullmatch('[A-Z]{2}',x) for x in rows):raise ValueError('countries must be two-letter codes')
    return list(dict.fromkeys(rows))

class GoogleGeoUnknown(RuntimeError):
    """No Google/YouTube country was observed through the selected proxy."""

def youtube_enabled():
    return POLICY.get('youtube_mode',False) is True

def geo_reason(geo,region,strict=False):
    # RU is mandatory in YouTube mode, regardless of the ordinary deny/strict policy.
    # The saved policies remain untouched for when YouTube mode is disabled.
    if youtube_enabled():
        return '' if geo=='RU' else f'YouTube requires Google=RU; got {geo or "UNKNOWN"}'
    if geo in POLICY.get('deny_regions',['RU']):return f'Google={geo}'
    if strict and region and geo!=region:return f'Google={geo} != requested {region}'
    return ''

def boot_id():
    try:return Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    except OSError:return ''

def youtube_report(status,ip=None,geo=None,diag=None,speed=None,pin=False,detail=''):
    if not youtube_enabled():return
    path=DATA/'youtube-status.json';old=read_json(path,{}) or {}
    now=dt.datetime.now(dt.timezone.utc).isoformat()
    try:session=started_at()
    except Exception:session=None
    obj={'status':status,'ip':ip,'google_region':geo or 'UNKNOWN',
         'diagnostic_id':diag,'speed_kib_s':speed,'pin_verified':bool(pin),
         'checked_at':now,'boot_id':boot_id(),'container_started_at':session,
         'last_success_at':old.get('last_success_at'),'detail':detail}
    if geo=='RU' and status in ('RU VERIFIED','PIN VERIFIED'):obj['last_success_at']=now
    atomic_json(path,obj)

def youtube_observation(ip,geo,verdict,speed,reason='',pin=False,diag=None):
    if not youtube_enabled():return
    speed_unknown=bool(POLICY.get('min_speed_kib')) and speed is None
    detail=reason or speed_reason(speed) or ('Speed probe UNKNOWN; awaiting a new sample' if speed_unknown else '')
    status=('UNKNOWN' if not re.fullmatch('[A-Z]{2}',str(geo or '')) else
            'SEARCHING' if geo!='RU' else
            'DEGRADED' if detail else
            'PIN VERIFIED' if pin else 'RU VERIFIED')
    youtube_report(status,ip,geo,diag,speed,pin and status=='PIN VERIFIED',detail)

def youtube_status(settings=None,live=True):
    cfg=settings if settings is not None else POLICY
    if not cfg.get('youtube_mode',False):return {'status':'DISABLED'}
    obj=read_json(DATA/'youtube-status.json',{}) or {'status':'UNKNOWN'}
    stale=obj.get('boot_id')!=boot_id()
    try:
        age=(dt.datetime.now(dt.timezone.utc)-dt.datetime.fromisoformat(obj['checked_at'])).total_seconds()
        stale=stale or not 0<=age<=max(600,2*int(cfg.get('interval',300)))
        if live and obj.get('status') in ('RU VERIFIED','PIN VERIFIED'):
            stale=stale or obj.get('container_started_at')!=started_at()
    except (KeyError,ValueError,TypeError,RuntimeError,subprocess.SubprocessError,OSError):stale=True
    if stale:
        obj=dict(obj,last_status=obj.get('status'),status='UNKNOWN',pin_verified=False,detail='A fresh check is required after a restart or stale observation')
    return obj

def xray_routing(youtube_instance,gemini_instance):
    """Export a fragment only. Never read or modify an Xray installation."""
    if youtube_instance==gemini_instance:raise ValueError('YouTube and Gemini require different instances')
    out=[];configs=[]
    for number,tag in ((youtube_instance,'psiphon-youtube'),(gemini_instance,'psiphon-gemini')):
        if not 1<=number<=99:raise ValueError('instance must be 1..99')
        directory=DATA.parent/('psiphon-autopin'+('' if number==1 else f'-{number}'))
        cfg=read_json(directory/'settings.json',{}) or {}
        if not cfg:raise ValueError(f'Instance {number} is not installed')
        configs.append(cfg);address=cfg.get('bind','127.0.0.1');port=int(cfg['port'])
        if not 1024<=port<=65534:raise ValueError('invalid saved port')
        out.append({'tag':tag,'protocol':'socks','settings':{'servers':[{'address':address,'port':port}]}})
    yt,gm=configs
    if not yt.get('youtube_mode') or yt.get('gemini_check'):raise ValueError('YouTube instance must enable YouTube and disable Gemini')
    if not gm.get('gemini_check') or gm.get('youtube_mode'):raise ValueError('Gemini instance must enable Gemini and disable YouTube')
    if yt.get('tunnel_pool',1)!=1 or not ipaddress.ip_address(yt.get('bind','127.0.0.1')).is_loopback:
        raise ValueError('YouTube requires one tunnel on loopback')
    ports=[set((int(c['port']),int(c['port'])+1)) if c.get('publish_http',True) else {int(c['port'])} for c in configs]
    if ports[0]&ports[1]:raise ValueError('Instance proxy ports overlap')
    yt_domains=['domain:youtube.com','domain:youtu.be','domain:googlevideo.com','domain:ytimg.com','full:youtubei.googleapis.com']
    gm_domains=['domain:gemini.google.com','domain:aistudio.google.com','full:generativelanguage.googleapis.com']
    out.append({'tag':'psiphon-quic-block','protocol':'blackhole','settings':{}})
    rules=[{'type':'field','network':'udp','port':'443','domain':yt_domains+gm_domains,'outboundTag':'psiphon-quic-block'},
           {'type':'field','network':'tcp','domain':yt_domains,'outboundTag':'psiphon-youtube'},
           {'type':'field','network':'tcp','domain':gm_domains,'outboundTag':'psiphon-gemini'}]
    return {'outbounds':out,'routing':{'domainStrategy':'AsIs','rules':rules}}

def speed_reason(speed):
    floor=float(POLICY.get('min_speed_kib',0))
    return f'Slow exit: {speed:.1f} < {floor:.1f} KiB/s' if floor and speed is not None and speed<floor else ''

def save_region(region):
    update_region_env(region)
    clear_target(region)
    cfg=read_json(DATA/'settings.json',{}) or {};cfg['region']=region
    atomic_json(DATA/'settings.json',cfg)
    STATE.unlink(missing_ok=True)

def rotation_regions(region):
    pool=countries(POLICY.get('region_pool',[]))
    if len(pool)<2:return [region]
    if region in pool:
        i=pool.index(region)+1;return pool[i:]+pool[:i]
    return pool

def remember_pin(candidate,region):
    path=DATA/'verified-reserve.json'
    data=read_json(path,{}) or {}
    rows=[x for x in data.get(region,[]) if x.get('diagnostic')!=candidate['diagnostic']]
    data[region]=[candidate,*rows][:8]
    atomic_json(path,data)

def prioritized_candidates(rows,region):
    saved=(read_json(DATA/'verified-reserve.json',{}) or {}).get(region,[])
    # Only fresh DB entries are used; the reserve changes ordering, never invents credentials.
    rank={x.get('diagnostic'):i for i,x in enumerate(saved)}
    random.shuffle(rows)
    return sorted(rows,key=lambda x:rank.get(x['diagnostic'],1000))

def log(message):
    print(dt.datetime.now().astimezone().isoformat(timespec='seconds'),message,flush=True)

def run(args, timeout=60, merge=False, accepted_codes=(0,)):
    p=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.STDOUT if merge else subprocess.PIPE,text=True,timeout=timeout)
    if p.returncode not in accepted_codes:
        error=p.stdout if merge else p.stderr
        raise RuntimeError(f'{args[0]} rc={p.returncode}: {(error or "")[-450:]}')
    return p.stdout

def read_json(p, default=None):
    try:return json.loads(Path(p).read_text())
    except (OSError,ValueError):return default

def atomic_json(p, obj):
    p=Path(p);p.parent.mkdir(parents=True,exist_ok=True)
    st=p.stat() if p.exists() else None
    name=None
    try:
        with tempfile.NamedTemporaryFile('w',dir=p.parent,prefix='.autopin-',delete=False) as f:
            name=f.name;json.dump(obj,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
        if st:os.chown(name,st.st_uid,st.st_gid);os.chmod(name,st.st_mode & 0o777)
        else:os.chmod(name,0o600)
        os.replace(name,p)
        # Persist the rename as well as its contents across an unclean reboot.
        directory=os.open(p.parent,os.O_RDONLY|os.O_DIRECTORY)
        try:os.fsync(directory)
        finally:os.close(directory)
    finally:
        if name and os.path.exists(name):os.unlink(name)

def change_config(updates):
    obj=read_json(CONFIG)
    if not isinstance(obj,dict):raise RuntimeError('Invalid Psiphon configuration')
    obj.update(updates)
    atomic_json(CONFIG,obj)

def backend():
    value=(read_json(DATA/'settings.json',{}) or {}).get('backend','console')
    if value not in ('console','vps-psiphon'):raise RuntimeError('Invalid saved backend')
    return value

def tunnel_action(action):
    # A --rm container owned by systemd cannot be stopped/restarted via Docker:
    # systemd would race discovery and reopen BoltDB while the exporter reads it.
    if backend()=='vps-psiphon':
        return run(['systemctl',action,CONTAINER+'.service'],timeout=120)
    return run(['docker',action,CONTAINER],timeout=90)

def update_region_env(region):
    if backend()!='vps-psiphon':return
    path=ENV_FILE
    lines=path.read_text().splitlines()
    lines=[line for line in lines if line.split('=',1)[0] not in ('EGRESS_REGION','REGION_POOL')]
    # Same-directory atomic replacement, retaining owner/mode of the env file.
    st=path.stat();name=None
    try:
        with tempfile.NamedTemporaryFile('w',dir=path.parent,delete=False) as f:
            name=f.name
            f.write('\n'.join(lines+[f'EGRESS_REGION={region}',"REGION_POOL=''"])+ '\n')
            f.flush();os.fsync(f.fileno())
        os.chown(name,st.st_uid,st.st_gid);os.chmod(name,st.st_mode & 0o777)
        os.replace(name,path)
        directory=os.open(path.parent,os.O_RDONLY|os.O_DIRECTORY)
        try:os.fsync(directory)
        finally:os.close(directory)
    finally:
        if name and os.path.exists(name):os.unlink(name)

def set_region(region,wait,clear_pool=False):
    """Persist region, discard the old target and reconnect under the writer lock."""
    settings=read_json(DATA/'settings.json',{}) or {}
    config=read_json(CONFIG)
    if not isinstance(config,dict):raise RuntimeError('Invalid Psiphon configuration')
    env_matches=True
    if backend()=='vps-psiphon':
        values=[shlex.split(line.split('=',1)[1],comments=True)
                for line in ENV_FILE.read_text().splitlines() if line.startswith('EGRESS_REGION=')]
        env_matches=(values==[[region]] if region else values==[[]] or values==[['']])
    if env_matches and settings.get('region','')==region and config.get('EgressRegion','')==region:
        if clear_pool:
            settings['region_pool']=[];atomic_json(DATA/'settings.json',settings);POLICY['region_pool']=[]
        log(f'Region already {region or "AUTO"}; tunnel unchanged')
        return
    stamp=dt.datetime.now(dt.timezone.utc).strftime('%Y%m%d-%H%M%S-%f')
    backup=DATA/f'region-backup-{stamp}'
    backup.mkdir(mode=0o700)
    for path in (CONFIG,DATA/'settings.json',STATE,CACHE):
        if path.is_file():shutil.copy2(path,backup/path.name)
    if backend()=='vps-psiphon':
        shutil.copy2(ENV_FILE,backup/'vps-psiphon')
    update_region_env(region)
    change_config({'EgressRegion':region,'TargetServerEntry':'','TunnelPoolSize':int(POLICY.get('tunnel_pool',1))})
    settings['region']=region
    if clear_pool:settings['region_pool']=[];POLICY['region_pool']=[]
    atomic_json(DATA/'settings.json',settings)
    STATE.unlink(missing_ok=True);CACHE.unlink(missing_ok=True)
    log(f'Region saved: {region or "AUTO"}; backup={backup}; reconnecting')
    docker_restart(wait)
    log('SOCKS5 tunnel ready; the monitor will check Google/Gemini separately')

def socks_ip():
    # Explicit SOCKS5h proxy, remote DNS, no direct fallback or proxy bypass.
    ip=run(['curl','-4','-fsS','--connect-timeout','7','--max-time','15','--noproxy','', '--proxy',f'socks5h://{PROXY}','https://api.ipify.org'],timeout=20).strip()
    if ipaddress.ip_address(ip).version!=4:raise RuntimeError('Unexpected IPv4 address')
    return ip

def google_region():
    try:
        page=run(['curl','-4','-fsS','--max-time','25','--noproxy','','--proxy',f'socks5h://{PROXY}',
                  '-H','Accept-Language: en-US','https://www.youtube.com/'],timeout=30)
        found=re.search(r'"GL"\s*:\s*"([A-Z]{2})"',page)
        if found:return found.group(1)
    except Exception as exc:log('Fast Google classifier unavailable: '+str(exc))
    if youtube_enabled() or not POLICY.get('legacy_geo_fallback',False):raise GoogleGeoUnknown('Google country UNKNOWN')
    script=BASE/'ipregion.sh'
    if not script.is_file():raise RuntimeError('ipregion missing')
    env=os.environ.copy()
    # Also force any helper curl executed by ipregion through Psiphon.
    # run() does not accept env, so call subprocess explicitly here.
    env.update(ALL_PROXY=f'socks5h://{PROXY}',HTTP_PROXY=f'socks5h://{PROXY}',HTTPS_PROXY=f'socks5h://{PROXY}',http_proxy=f'socks5h://{PROXY}',https_proxy=f'socks5h://{PROXY}',all_proxy=f'socks5h://{PROXY}',NO_PROXY='',no_proxy='')
    cmd=['bash',str(script),'--proxy',PROXY,'--ipv4','--group','custom','--json']
    p=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=210,env=env)
    if p.returncode:raise RuntimeError(f'ipregion failed: {p.stderr[-350:]}')
    report=json.loads(p.stdout)
    rows=report.get('results',{}).get('custom',[])
    geo=[str(x.get('ipv4','')).strip().upper() for x in rows if x.get('service')=='Google']
    if len(geo)!=1 or not re.fullmatch('[A-Z]{2}',geo[0]):raise GoogleGeoUnknown(f'Google region UNKNOWN: {geo}')
    return geo[0]

def probe():
    first=socks_ip()
    for attempt in range(3 if youtube_enabled() else 1):
        try:country=google_region();break
        except GoogleGeoUnknown:
            if not youtube_enabled() or attempt==2:raise
            youtube_report('UNKNOWN',ip=first,detail='Retrying Google GeoIP through SOCKS5h')
            time.sleep(10)
    last=socks_ip()
    if first!=last:raise RuntimeError(f'Exit changed during check: {first} -> {last}')
    log(f'Exit={last}, Google={country} [SOCKS5h]')
    return last,country

def gemini_verdict(enabled):
    """Report only explicit refusal; never treat inconclusive as bad exit."""
    if not enabled:return 'DISABLED'
    port=PROXY.rsplit(':',1)[1]
    cmd=['python3',str(BASE/'gemini_probe.py'),'--port',port,'--host',PROXY.rsplit(':',1)[0]]
    if POLICY.get('impersonate'):
        cmd+=['--impersonate-dir',str(BASE/'curl-impersonate')]
    p=subprocess.run(cmd,
                     stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=185)
    label={0:'SERVING',1:'REFUSED',2:'INCONCLUSIVE',3:'CAPTCHA'}.get(p.returncode,'INCONCLUSIVE')
    log('Gemini '+label+': '+(p.stdout or p.stderr).strip()[-180:])
    return label

def speed_probe(mb):
    """Measure after the first byte, so connection setup is not mistaken for poor throughput."""
    if mb<=0 and not POLICY.get('min_speed_kib'):return None
    url=f'https://speed.cloudflare.com/__down?bytes={mb*1048576}' if mb else 'https://www.youtube.com/'
    cmd=['curl','-4','-fsS','--noproxy','','--proxy',f'socks5h://{PROXY}',
         '--connect-timeout','8','--max-time','50','-o','/dev/null',
         '-w','%{size_download} %{time_starttransfer} %{time_total} %{http_code}',url]
    size,first,total,code=run(cmd,timeout=55,accepted_codes=(0,28)).strip().split()
    elapsed=float(total)-float(first)
    if int(code) not in (200,206) or float(size)<50000 or elapsed<=0:raise RuntimeError('Insufficient throughput sample')
    speed=round(float(size)/elapsed/1024,1)
    log(f'Speed probe: {speed} KiB/s after first byte, sample={mb} MiB')
    return speed

def evaluate_exit(region, gemini, mb, strict=False):
    ip,geo=probe()
    verdict=gemini_verdict(gemini)
    speed=None
    if mb or POLICY.get('min_speed_kib'):
        try:speed=speed_probe(mb)
        except Exception as exc:log('Optional speed sample failed: '+str(exc))
    # Google classifications can differ from the server's requested country.
    # In strict mode reject *confirmed* mismatch, not an inconclusive Gemini reply.
    reason=geo_reason(geo,region,strict) or ('Gemini REFUSED' if verdict=='REFUSED' else 'Gemini CAPTCHA' if verdict=='CAPTCHA' else '')
    youtube_observation(ip,geo,verdict,speed,reason)
    return ip,geo,verdict,speed,reason

def adopt_current(region,gemini,mb,strict,observed=None,auto_pin=True):
    """Keep a healthy tunnel; recover an existing target only against the cached DB entry."""
    config=read_json(CONFIG,{}) or {}
    ip,geo,verdict,speed,reason = observed if observed is not None else evaluate_exit(region,gemini,mb,strict)
    if reason or geo_reason(geo,region,strict) or speed_reason(speed):return False
    diag=connected_id()
    if config.get('TargetServerEntry'):
        staged=read_json(STATE,{}) or {}
        if staged.get('pin_prepared') and started_at()==staged.get('prepared_container_started_at'):
            log('Prepared target still pending a new container start; preserving unverified state')
            return True
        # Search can be interrupted after writing a target but before saving its state.
        # Require both the cached credential blob and the live diagnostic ID to match.
        row=candidate_for_connected_server(diag,region)
        if not row or row['encoded']!=config['TargetServerEntry']:
            log('Healthy targeted tunnel has no matching cached entry; pin remains unverified')
            return False
        if socks_ip()!=ip or connected_id()!=diag:
            raise RuntimeError('Targeted exit changed during pin recovery')
        atomic_json(STATE,{'region':region,'ip':ip,'google_region':geo,
            'diagnostic_id':diag,'server_ip':row['server_ip'],'gemini':verdict,
            'speed_kib_s':speed,'adopted_unpinned':False,
            'verified_at':dt.datetime.now(dt.timezone.utc).isoformat()})
        remember_pin(row,region)
        youtube_observation(ip,geo,verdict,speed,pin=True,diag=diag)
        log(f'RECOVERED VERIFIED PIN: exit={ip} Google={geo} Gemini={verdict} '
            f'server={row["server_ip"]} ID={diag}; no restart')
        activity_report('VERIFIED','PIN проверен',gemini=verdict)
        return True
    atomic_json(STATE,{'region':region,'ip':ip,'google_region':geo,
        'diagnostic_id':diag,'server_ip':None,'gemini':verdict,
        'speed_kib_s':speed,'adopted_unpinned':True,
        'verified_at':dt.datetime.now(dt.timezone.utc).isoformat()})
    youtube_observation(ip,geo,verdict,speed,diag=diag)
    log(f'ADOPTED HEALTHY exit={ip} Google={geo} Gemini={verdict} ID={diag}; no restart (not targeted pin)')
    if auto_pin:auto_pin_current(region,gemini,mb,strict)
    activity_report('VERIFIED','Выход проверен',gemini=verdict)
    return True

def started_at():
    return run(['docker','inspect','-f','{{.State.StartedAt}}',CONTAINER]).strip()

def connected_id():
    data=run(['docker','logs','--since',started_at(),CONTAINER],timeout=30,merge=True)
    last=None
    for line in data.splitlines():
        try: obj=json.loads(line)
        except ValueError:continue
        if obj.get('noticeType')=='ConnectedServer':last=(obj.get('data') or {}).get('diagnosticID')
    if not last or not re.fullmatch(r'[A-Za-z0-9+/]{8}',last):raise RuntimeError('No valid ConnectedServer ID in current Docker session')
    return last

def db_path():
    matches=list(CONFIG.parent.glob('**/psiphon.boltdb'))
    if len(matches)!=1:raise RuntimeError(f'Expected exactly one BoltDB, got {len(matches)}')
    return matches[0]

# A candidate snapshot is obtained ONLY when Psiphon is already stopped as
# part of normal server discovery. Never open/copy a live BoltDB for staging.
CACHE=DATA/'server-entry-cache.json'

def cache_candidates(rows,region):
    # TargetServerEntry contains server credentials. Store only under mode 0600.
    atomic_json(CACHE, {'region':region,'entries':rows,
        'cached_at':dt.datetime.now(dt.timezone.utc).isoformat()})

def candidate_for_connected_server(diag,region):
    cache=read_json(CACHE,{}) or {}
    if cache.get('region')!=region:return None
    rows=[r for r in cache.get('entries',[]) if r.get('diagnostic')==diag and
          (not region or r.get('region')==region) and r.get('encoded') and r.get('server_ip')]
    # Diagnostic IDs are shortened tags, so do not silently choose between collisions.
    if len(rows)!=1:return None
    return rows[0]

def prepare_current_pin(region,ip,geo,diag):
    """Write next-start target without touching the running tunnel.

    This is staged, NOT verified. We intentionally don't restart ConsoleClient.
    """
    cfg=read_json(CONFIG,{}) or {}
    state=read_json(STATE,{}) or {}
    if cfg.get('TargetServerEntry') or state.get('pin_prepared'):return False
    candidate=candidate_for_connected_server(diag,region)
    if candidate is None:return False
    # Recheck the exit and diagnostic ID across the staging boundary.
    if socks_ip()!=ip or connected_id()!=diag:return False
    running_since=started_at()
    change_config({'TargetServerEntry':candidate['encoded'], 'EgressRegion':region,
                   'TunnelPoolSize':1,'EmitDiagnosticNotices':True,'DisableReplay':True})
    state.update(server_ip=candidate['server_ip'],adopted_unpinned=True,
                 pin_prepared=True,prepared_container_started_at=running_since)
    atomic_json(STATE,state)
    log(f'PIN PREPARED: ID={diag}, server={candidate["server_ip"]}; '
        'takes effect on next Psiphon restart; current tunnel unchanged')
    return True

def pin_prepared_verification(region,ip,geo,diag,reason,state):
    """Promote staged pin only after a NEW container instance has confirmed it."""
    if not state.get('pin_prepared'):return False
    if started_at()==state.get('prepared_container_started_at'):
        log(f'Prepared pin pending next restart: {ip} Google={geo}; current tunnel unchanged')
        return True
    if not reason and not geo_reason(geo,region) and ip==state.get('ip') and diag==state.get('diagnostic_id'):
        state.update(pin_prepared=False,adopted_unpinned=False,
                     verified_at=dt.datetime.now(dt.timezone.utc).isoformat())
        state.pop('prepared_container_started_at',None)
        atomic_json(STATE,state)
        youtube_observation(ip,geo,state.get('gemini'),state.get('speed_kib_s'),pin=True,diag=diag)
        log(f'PIN VERIFIED AFTER RESTART: exit={ip} Google={geo} ID={diag}')
        return True
    # A prepared target failed to restore the previous verified exit.
    # Do not claim it was pinned; the monitor can run normal recovery.
    log(f'Prepared pin mismatch after restart: current={ip}/{diag}; '
        f'expected={state.get("ip")}/{state.get("diagnostic_id")}')
    return False

def wait_ready(wait):
    """Wait for an existing tunnel without restarting a potentially healthy pin."""
    deadline=time.monotonic()+wait;error='unknown'
    while time.monotonic()<deadline:
        try:return socks_ip()
        except Exception as exc:error=str(exc);time.sleep(2)
    raise RuntimeError(f'Psiphon not ready in {wait}s: {error}')

def docker_restart(wait):
    tunnel_action('restart')
    return wait_ready(wait)

def export_candidates_stopped(region):
    raw=run([str(BASE/'psiphon-server-export'),str(db_path()),region],timeout=120)
    rows=[json.loads(line) for line in raw.splitlines() if line.strip()]
    rows=[v for v in rows if v.get('server_ip') and v.get('diagnostic') and v.get('encoded')]
    if not rows:raise RuntimeError(f'No known servers in region {region or "AUTO"}')
    cache_candidates(rows,region)
    log(f'Loaded {len(rows)} distinct servers')
    return rows

def collect_candidates(region):
    log('Exporting distinct server entries from read-only BoltDB...')
    tunnel_action('stop')
    try:return export_candidates_stopped(region)
    finally:tunnel_action('start')

def auto_pin_current(region,gemini=False,mb=0,strict=False,wait=None):
    """Populate the stopped DB cache, connect to the observed server, then verify."""
    cfg=read_json(CONFIG,{}) or {};state=read_json(STATE,{}) or {}
    if int(POLICY.get('tunnel_pool',1))!=1 or cfg.get('TargetServerEntry') or not state.get('adopted_unpinned') or speed_reason(state.get('speed_kib_s')) or geo_reason(state.get('google_region'),region):
        return False
    retry_path=DATA/'initial-pin-attempt.json'
    retry=read_json(retry_path,{}) or {};now=time.time()
    if retry.get('region')==region and float(retry.get('retry_after',0))>now:return False
    # Failure never causes a tight reconnect loop; retry on a later normal health cycle.
    atomic_json(retry_path,{'region':region,'retry_after':now+max(60,int(POLICY.get('interval',300)))})
    expected=state.get('diagnostic_id');initial_ip=state.get('ip');changed=False
    wait=int(wait if wait is not None else POLICY.get('wait',75))
    try:
        if not expected or connected_id()!=expected or socks_ip()!=initial_ip:
            raise RuntimeError('Current exit changed before initial pin')
        old_start=started_at()
        log(f'INITIAL PIN: building cache for ID={expected}; one controlled reconnect')
        tunnel_action('stop')
        try:
            export_candidates_stopped(region)
            candidate=candidate_for_connected_server(expected,region)
            if candidate is None:raise RuntimeError('Current server has no unique datastore entry')
            changed=True
            pending=dict(state);pending.update(pin_prepared=True,prepared_container_started_at=old_start)
            atomic_json(STATE,pending)
            apply_candidate(candidate,region)
        finally:
            tunnel_action('start')
        wait_ready(wait)
        if started_at()==old_start:raise RuntimeError('No new container start observed')
        ip,geo,verdict,speed,reason=evaluate_exit(region,gemini,mb,strict)
        if reason or speed_reason(speed):raise RuntimeError('Pinned exit did not pass current policy')
        if connected_id()!=expected:raise RuntimeError('Pinned server ID mismatch')
        time.sleep(2)
        if socks_ip()!=ip or connected_id()!=expected:raise RuntimeError('Pinned exit changed during verification')
        if youtube_enabled():
            confirmed_ip,confirmed_geo=probe()
            if confirmed_ip!=ip or geo_reason(confirmed_geo,region,strict):raise RuntimeError('YouTube GeoIP changed during PIN verification')
        if (read_json(CONFIG,{}) or {}).get('TargetServerEntry')!=candidate['encoded']:
            raise RuntimeError('Configured target changed during verification')
        atomic_json(STATE,{'region':region,'ip':ip,'google_region':geo,'gemini':verdict,
            'speed_kib_s':speed,'diagnostic_id':expected,'server_ip':candidate['server_ip'],
            'adopted_unpinned':False,'pin_prepared':False,
            'verified_at':dt.datetime.now(dt.timezone.utc).isoformat()})
    except Exception as exc:
        youtube_report('UNKNOWN' if isinstance(exc,GoogleGeoUnknown) else 'DEGRADED',detail='Initial PIN deferred: '+str(exc))
        if changed:
            atomic_json(CONFIG,cfg);atomic_json(STATE,state)
            try:docker_restart(wait)
            except Exception as restore_error:
                raise RuntimeError('Initial PIN rollback could not restore proxy') from restore_error
        else:
            try:wait_ready(wait)
            except Exception as recovery_error:
                raise RuntimeError('Initial PIN attempt left proxy unavailable') from recovery_error
        log(f'INITIAL PIN DEFERRED: {exc}; no verified PIN claimed; retry on a later health cycle')
        return False
    retry_path.unlink(missing_ok=True)
    try:remember_pin(candidate,region)
    except Exception as exc:log(f'PIN verified; reserve update deferred: {type(exc).__name__}')
    youtube_observation(ip,geo,verdict,speed,pin=True,diag=expected)
    log(f'INITIAL PIN VERIFIED: exit={ip} Google={geo} Gemini={verdict} ID={expected}; initial exit={initial_ip}')
    activity_report('VERIFIED','PIN проверен',gemini=verdict)
    return True


def apply_candidate(candidate,region):
    change_config({'EgressRegion':region,'TargetServerEntry':candidate['encoded'],'TunnelPoolSize':1,'EmitDiagnosticNotices':True,'DisableReplay':True})

def clear_target(region):
    update_region_env(region)
    change_config({'EgressRegion':region,'TargetServerEntry':'','TunnelPoolSize':int(POLICY.get('tunnel_pool',1)),'EmitDiagnosticNotices':True,'DisableReplay':True})

def verify_pin_current(region,gemini=False,mb=0,strict=False):
    state=read_json(STATE,{}) or {}
    config=read_json(CONFIG,{}) or {}
    if state.get('pin_prepared'):return False
    if state.get('region')!=region or not state.get('ip') or not config.get('TargetServerEntry'):
        return False
    ip,geo,verdict,speed,reason=evaluate_exit(region,gemini,mb,strict)
    diag=connected_id()
    if ip==state['ip'] and not reason and not geo_reason(geo,region,strict) and not speed_reason(speed) and diag==state.get('diagnostic_id'):
        youtube_observation(ip,geo,verdict,speed,pin=True,diag=diag)
        log(f'Existing pin healthy: {ip}, {geo}, server={diag}')
        activity_report('VERIFIED','PIN проверен',gemini=verdict)
        return True
    return False

def search(region,wait,delay,gemini=False,mb=0,strict=False):
    activity_report('SEARCHING','Поиск подходящего выхода')
    youtube_report('SEARCHING',detail='Searching for Google GeoIP RU')
    log(f'Server rotation started: {region or "AUTO"}; unlimited cycles')
    # A CLI region override must take effect before accepting the current exit.
    if (read_json(CONFIG,{}) or {}).get('EgressRegion','')!=region:
        clear_target(region)
        STATE.unlink(missing_ok=True)
        docker_restart(wait)
    # Preserve a known good pin without needless restart.
    try:
        if verify_pin_current(region,gemini,mb,strict):return True
        if adopt_current(region,gemini,mb,strict):return True
    except Exception as e:log(f'Existing pin check failed: {e}')
    # Remove old target before discovery. No automatic return to RU state.
    clear_target(region)
    STATE.unlink(missing_ok=True)
    seen_exits=set()
    cycle=0
    pool=rotation_regions(region)
    while True:
        next_region=pool[cycle % len(pool)]
        if next_region!=region:
            region=next_region;save_region(region)
            log(f'Region pool advanced to {region}')
        cycle+=1
        try:
            # Give Psiphon an opportunity to discover new servers before snapshotting the DB.
            docker_restart(wait)
            time.sleep(5)
            candidates=collect_candidates(region)
        except Exception as exc:
            log(f'Cannot collect candidates: {exc}; retry in 30s')
            time.sleep(30)
            continue
        candidates=prioritized_candidates(candidates,region)
        log(f'Cycle {cycle}: {len(candidates)} unique server IPs')
        for i,candidate in enumerate(candidates,1):
            server=candidate['server_ip'];expected=candidate['diagnostic']
            log(f'Trying server {i}/{len(candidates)}: {server}, ID={expected}')
            activity_report('SEARCHING',f'Кандидат {i}/{len(candidates)}, цикл {cycle}',candidate=i,total=len(candidates),cycle=cycle)
            try:
                apply_candidate(candidate,region)
                exit_ip=docker_restart(wait)
                actual=connected_id()
                if actual!=expected:
                    raise RuntimeError(f'Wrong server ID: expected {expected}, got {actual}')
                # Do not spend time probing Google for an exit already rejected.
                if exit_ip in seen_exits:
                    log(f'Exit {exit_ip} already rejected in this search; skipping')
                    continue
                first,geo,verdict,speed,reason=evaluate_exit(region,gemini,mb,strict)
                if first!=exit_ip:raise RuntimeError(f'Exit IP changed: {exit_ip} -> {first}')
                reason=reason or speed_reason(speed)
                if reason:
                    seen_exits.add(first)
                    activity_report('SEARCHING',f'Кандидат {i}/{len(candidates)} отклонён: {reason}',gemini=verdict)
                    log(f'Rejected exit {first}: {reason}')
                    continue
                # Recheck IP/geo, without an unnecessary second Gemini request.
                time.sleep(5)
                second,geo2=probe()
                if second!=first or geo_reason(geo2,region,strict) or connected_id()!=expected:
                    raise RuntimeError(f'Pin verification unstable: {second} Google={geo2}')
                atomic_json(STATE,{'ip':first,'google_region':geo2,'region':region,'diagnostic_id':expected,
                                   'server_ip':server,'gemini':verdict,'speed_kib_s':speed,
                                   'adopted_unpinned':False,'verified_at':dt.datetime.now(dt.timezone.utc).isoformat()})
                remember_pin(candidate,region)
                youtube_observation(first,geo2,verdict,speed,pin=True,diag=expected)
                log(f'PIN VERIFIED: exit={first} Google={geo2} Gemini={verdict} server={server} ID={expected}')
                activity_report('VERIFIED','PIN проверен',gemini=verdict)
                return True
            except Exception as exc:
                youtube_report('UNKNOWN' if isinstance(exc,GoogleGeoUnknown) else 'DEGRADED',detail=str(exc))
                activity_report('SEARCHING',f'Кандидат {i}/{len(candidates)} недоступен; поиск продолжается')
                log(f'Server {server} failed: {exc}')
            finally:
                time.sleep(delay)
        log('All candidates exhausted. Refreshing discovery and repeating in 60s...')
        clear_target(region)
        try:docker_restart(wait)
        except Exception as e:log(f'Discovery connection warning: {e}')
        time.sleep(60)
        # After a full cycle, the same exit could have been reclassified by Google.
        seen_exits.clear()

def monitor(region,interval,wait,delay,gemini=False,mb=0,strict=False,threshold=3):
    activity_report('CHECKING','Ожидание проверки текущего запуска')
    log(f'Monitor v4.3: region={region or "AUTO"} interval={interval}s Gemini={gemini} speedMB={mb}')
    youtube_report('UNKNOWN',detail='Waiting for startup verification')
    failures=0;slow_count=0;slow_identity=None
    try:wait_ready(wait)
    except Exception as exc:log(f'Startup readiness pending: {exc}')
    while True:
        next_check=interval
        region=(read_json(DATA/'settings.json',{}) or {}).get('region',region) if POLICY.get('region_pool') else region
        try:
            ip,geo,verdict,speed,reason=evaluate_exit(region,gemini,mb,strict)
            state=read_json(STATE,{}) or {}
            config=read_json(CONFIG,{}) or {}
            diag=connected_id()
            youtube_observation(ip,geo,verdict,speed,reason,pin=bool(config.get('TargetServerEntry') and not state.get('adopted_unpinned',True) and not state.get('pin_prepared') and diag==state.get('diagnostic_id') and ip==state.get('ip')),diag=diag)
            identity=(ip,diag,started_at())
            if identity!=slow_identity:slow_count=0;slow_identity=identity
            slow=speed_reason(speed)
            slow_count=slow_count+1 if slow else 0
            if slow:
                log(f'{slow}; confirmation {slow_count}/{POLICY.get("slow_threshold",2)}')
                if slow_count>=int(POLICY.get('slow_threshold',2)):
                    log('Confirmed low throughput; searching for a faster exit')
                    search(region,wait,delay,gemini,mb,strict)
                    slow_count=0;failures=0
                    time.sleep(interval);continue
                next_check=min(interval,30)
            changed=bool(state) and (ip!=state.get('ip') or diag!=state.get('diagnostic_id'))
            if not reason and not speed_reason(speed) and state.get('pin_prepared') and config.get('TargetServerEntry'):
                if pin_prepared_verification(region,ip,geo,diag,reason,state):
                    failures=0
                    time.sleep(interval)
                    continue
            if reason:
                log(f'Bad exit: {reason}; verifying before rotation')
                # Confirm decisive refusals to avoid spurious reboots.
                time.sleep(10)
                ip2,geo2,verdict2,_,reason2=evaluate_exit(region,gemini,0,strict)
                if reason2 and ip2==ip:
                    log(f'Confirmed bad exit ({reason2}); starting search')
                    search(region,wait,delay,gemini,mb,strict)
                else:log('Second check recovered/inconclusive: preserving connection')
                failures=0
            elif not state or (not config.get('TargetServerEntry') and not state.get('adopted_unpinned')):
                # Existing working tunnel is useful even without TargetServerEntry.
                adopt_current(region,gemini,mb,strict,observed=(ip,geo,verdict,speed,reason))
                failures=0
            elif changed or state.get('region')!=region:
                log('Exit/region changed; evaluating current healthy exit')
                if not config.get('TargetServerEntry'):
                    adopt_current(region,gemini,mb,strict,observed=(ip,geo,verdict,speed,reason))
                else:
                    search(region,wait,delay,gemini,mb,strict)
                failures=0
            else:
                failures=0
                # Persist each completed health check, without changing the pin identity.
                if state:
                    state.update(google_region=geo, gemini=verdict, speed_kib_s=speed,
                                 verified_at=dt.datetime.now(dt.timezone.utc).isoformat())
                    atomic_json(STATE,state)
                    activity_report('VERIFIED','Проверка выхода завершена',gemini=verdict)
                if state.get('adopted_unpinned') and not config.get('TargetServerEntry'):
                    if auto_pin_current(region,gemini,mb,strict,wait):
                        failures=0;time.sleep(interval);continue
                log(f'Healthy exit unchanged: {ip} Google={geo} Gemini={verdict}; '
                    + ('adopted (not pinned)' if state.get('adopted_unpinned') else 'pinned'))
        except Exception as exc:
            youtube_report('UNKNOWN' if isinstance(exc,GoogleGeoUnknown) else 'DEGRADED',detail=str(exc))
            if youtube_enabled() and isinstance(exc,GoogleGeoUnknown):
                log('YouTube GeoIP UNKNOWN; retrying without accepting or restarting the server')
                failures=0;time.sleep(min(interval,30));continue
            slow_count=0
            failures+=1
            # An outage must not postpone retries for a full hourly health interval.
            next_check=min(interval,30)
            log(f'UNKNOWN/OUTAGE {failures}/{threshold}: {exc}; no RU inference')
            if failures>=threshold:
                log('Consecutive failures reached threshold; recovering connection')
                try:
                    try:
                        docker_restart(wait)
                    except Exception as restart_error:
                        # A dead TargetServerEntry must not be retried forever.
                        log(f'Restart could not restore SOCKS: {restart_error}; discovering another server')
                        search(region,wait,delay,gemini,mb,strict)
                    else:
                        # A failed Google classifier is not proof of a bad exit.
                        ip,geo,verdict,_,reason=evaluate_exit(region,gemini,0,strict)
                        if reason:
                            search(region,wait,delay,gemini,mb,strict)
                        else:
                            log(f'Recovered without full search: {ip} Google={geo} Gemini={verdict}')
                except Exception as e:
                    log(f'Recovery incomplete: {e}; defer next attempt')
                failures=0
        time.sleep(next_check)

def pool_monitor(region,interval,wait,delay,gemini=False,mb=0,strict=False,threshold=3):
    """Check sampled exits of a multi-tunnel pool; no single-IP PIN claim is made."""
    if youtube_enabled():raise ValueError('YouTube mode requires a single tunnel for verified PIN')
    slow_count=0;failures=0
    log(f'Multi-tunnel monitor: {POLICY.get("tunnel_pool")} tunnels; PIN disabled')
    while True:
        next_check=interval
        try:
            region=(read_json(DATA/'settings.json',{}) or {}).get('region',region)
            ip=socks_ip();geo=google_region();verdict=gemini_verdict(gemini)
            speed=speed_probe(mb) if mb or POLICY.get('min_speed_kib') else None
            reason=(f'Google={geo}' if geo in POLICY.get('deny_regions',['RU']) else
                    verdict if verdict in ('REFUSED','CAPTCHA') else
                    'country mismatch' if strict and region and geo!=region else '')
            slow_count=slow_count+1 if speed_reason(speed) else 0
            if slow_count:
                next_check=min(interval,30)
                log(f'Low pool throughput: confirmation {slow_count}/{POLICY.get("slow_threshold",2)}; {speed_reason(speed)}')
            if reason or slow_count>=int(POLICY.get('slow_threshold',2)):
                region=rotation_regions(region)[0]
                log(f'Rotating pool: {reason or speed_reason(speed)}; next region={region or "AUTO"}')
                save_region(region);docker_restart(wait);slow_count=0
            else:
                atomic_json(STATE,{'region':region,'ip':ip,'google_region':geo,'gemini':verdict,
                    'speed_kib_s':speed,'tunnel_pool':int(POLICY.get('tunnel_pool',1)),
                    'adopted_unpinned':True,'pool_sample':True,
                    'verified_at':dt.datetime.now(dt.timezone.utc).isoformat()})
                log(f'Pool sample: exit={ip}, Google={geo}, Gemini={verdict}, speed={speed}')
            failures=0
        except Exception as exc:
            failures+=1;slow_count=0;next_check=min(interval,30)
            log(f'Pool check UNKNOWN {failures}/{threshold}: {exc}')
            if failures>=threshold:
                try:save_region(rotation_regions(region)[0]);docker_restart(wait)
                except Exception as error:log(f'Pool recovery pending: {error}')
                failures=0
        time.sleep(next_check)

def uninstall(purge_deps=False):
    """Remove just this instance; retain migration backups and any image used by others."""
    if os.geteuid()!=0:raise RuntimeError('Run as root')
    cleanup=None;dependency_module=None
    if (BASE/'autopin_system.py').is_file():
        import autopin_system
        cleanup=autopin_system.cleanup_dependencies;dependency_module=autopin_system
    elif purge_deps:
        raise RuntimeError('Dependency receipt helper missing; update Auto-Pin first')
    with (dependency_module.locked() if dependency_module else contextlib.nullcontext()):
        image=''
        try:
            mount=run(['docker','inspect','-f','{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}',CONTAINER]).strip()
            if mount!=str(CONFIG.parent):raise RuntimeError('Foreign container mount; refusing uninstall')
            image=run(['docker','inspect','-f','{{.Config.Image}}',CONTAINER]).strip()
        except RuntimeError as exc:
            if 'Foreign' in str(exc):raise
        for unit in (monitor_unit(),CONTAINER+'.service',CONTAINER+'-watchdog.timer',CONTAINER+'-watchdog.service'):
            subprocess.run(['systemctl','disable','--now',unit],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            (Path('/etc/systemd/system')/unit).unlink(missing_ok=True)
        subprocess.run(['docker','rm','-f',CONTAINER],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        for name in (CONTAINER,'psiphon-autopin'+('' if INSTANCE==1 else f'-{INSTANCE}'),CONTAINER+'-run',CONTAINER+'-prestart',CONTAINER+'-watchdog',CONTAINER+'-gemini-check',CONTAINER+'-advance-region'):
            (Path('/usr/local/sbin')/name).unlink(missing_ok=True)
        ENV_FILE.unlink(missing_ok=True)
        for path in (BASE,DATA,CONFIG.parent.parent):
            if path.exists():shutil.rmtree(path)
        run(['systemctl','daemon-reload'])
        if not any(Path('/opt').glob('psiphon-autopin*/autopin_menu.py')):
            launcher=Path('/usr/local/sbin/auto-pin')
            if launcher.is_file() and '# Managed by Forcus Auto-Pin menu' in launcher.read_text():launcher.unlink()
        if image:subprocess.run(['docker','image','rm',image],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        if cleanup:
            result=cleanup(purge=purge_deps,lock_held=True)
            print(json.dumps({'dependency_cleanup':result},indent=2))
            if any(isinstance(value,dict) and (value.get('exit_code',0)!=0 or value.get('remaining')) for value in result.values()):
                raise RuntimeError('Auto-Pin removed, but some owned dependencies could not be removed; receipt retained')
        print(f'Removed instance {INSTANCE}; backups under /var/backups/psiphon-autopin are retained')

def main():
    ap=argparse.ArgumentParser(description='Psiphon Auto-Pin v4.3')
    ap.add_argument('command',choices=['menu','check','search','monitor','status','config','refresh-cache','prepare-pin','set-region','set-pool','region','pool','rotate','start','stop','restart','logs','speed','uninstall','xray','xray-routing','update'])
    ap.add_argument('value',nargs='?')
    ap.add_argument('--instance',type=int,default=1)
    ap.add_argument('--all',action='store_true',help='Read-only status, logs, config or xray for all installed instances')
    ap.add_argument('--youtube-instance',type=int,default=1)
    ap.add_argument('--gemini-instance',type=int,default=2)
    ap.add_argument('--purge-deps',action='store_true',help='With uninstall: remove only Docker/Go installed by Auto-Pin and no longer used')
    ap.add_argument('--region-pool',default=None)
    ap.add_argument('--deny-regions',default=None)
    ap.add_argument('--min-speed',type=float,default=None)
    ap.add_argument('--slow-threshold',type=int,default=None)
    ap.add_argument('--impersonate',action='store_true',default=None)
    ap.add_argument('--no-impersonate',dest='impersonate',action='store_false')
    ap.add_argument('--region',default=None)
    ap.add_argument('--allow-interruption',action='store_true',help='Required for refresh-cache (briefly stops Psiphon)')
    ap.add_argument('--port',type=int,default=None)
    ap.add_argument('--interval',type=int,default=None)
    ap.add_argument('--wait',type=int,default=None)
    ap.add_argument('--delay',type=int,default=None)
    ap.add_argument('--gemini-check',action='store_true',default=None)
    ap.add_argument('--no-gemini-check',dest='gemini_check',action='store_false')
    ap.add_argument('--probe-mb',type=int,default=None)
    ap.add_argument('--strict-region',action='store_true',default=None)
    ap.add_argument('--no-strict-region',dest='strict_region',action='store_false')
    ap.add_argument('--fail-threshold',type=int,default=None)
    args=ap.parse_args()
    if args.all and args.command not in ('status','logs','config','xray'):ap.error('--all supports status, logs, config or xray only')
    if args.all:return all_views(args,view_instances())
    implicit_view=args.command in ('status','logs','config','xray') and sys.stdin.isatty() and sys.stdout.isatty() and not any(v=='--instance' or v.startswith('--instance=') for v in sys.argv[1:])
    if implicit_view and len(view_instances())==1:args.instance=view_instances()[0]
    if implicit_view and len(view_instances())>1:
        import autopin_menu as ui
        try:
            with open('/dev/tty','r',encoding='utf-8',errors='replace') as reader,open('/dev/tty','w',encoding='utf-8',buffering=1) as writer:
                targets=ui.Menu(ui.TerminalIO(reader,writer)).view_targets(args.command)
            return all_views(args,targets) if targets else 0
        except (EOFError,KeyboardInterrupt):return 0
    if args.purge_deps and args.command!='uninstall':ap.error('--purge-deps requires uninstall')
    force_rotate=(args.command=='rotate')
    if not 1<=args.instance<=99:ap.error('instance must be 1..99')
    if args.instance!=1:configure_instance(args.instance)
    if args.command in ('menu','update'):
        return subprocess.call([sys.executable,str(BASE/'autopin_menu.py'),'--instance',str(args.instance),*(['--update'] if args.command=='update' else [])])
    if args.command in ('region','pool'):
        if args.value is None:ap.error('region/pool requires a value')
        if args.command=='region':args.region=args.value;args.command='set-region'
        else:args.region_pool=args.value;args.command='set-pool'
    if args.command=='rotate':args.command='search'
    if args.command=='set-region' and args.region is None:ap.error('set-region requires --region CC|AUTO')
    settings=read_json(DATA/'settings.json',{}) or {}
    for key,default in [('interval',300),('wait',75),('delay',12)]:
        if getattr(args,key) is None:setattr(args,key,int(settings.get(key,default)))
    global POLICY
    POLICY=dict(settings)
    if type(POLICY.get('youtube_mode',False)) is not bool:ap.error('youtube_mode must be boolean')
    POLICY.update(interval=args.interval,wait=args.wait)
    for key,value in [('region_pool',args.region_pool),('deny_regions',args.deny_regions)]:
        if value is not None:
            try:POLICY[key]=countries(value)
            except ValueError as exc:ap.error(str(exc))
    if args.min_speed is not None:POLICY['min_speed_kib']=args.min_speed
    if args.slow_threshold is not None:POLICY['slow_threshold']=args.slow_threshold
    if args.impersonate is not None:POLICY['impersonate']=args.impersonate
    if not math.isfinite(float(POLICY.get('min_speed_kib',0))) or float(POLICY.get('min_speed_kib',0))<0 or int(POLICY.get('slow_threshold',2))<2:ap.error('min-speed>=0; slow-threshold>=2')
    # settings.json stores the effective service configuration for status and CLI.
    # Explicit CLI arguments still win over persisted settings.
    if args.gemini_check is None:args.gemini_check=bool(settings.get('gemini_check',False))
    if args.probe_mb is None:args.probe_mb=int(settings.get('probe_mb',0))
    if args.strict_region is None:args.strict_region=bool(settings.get('strict_region',False))
    if args.fail_threshold is None:args.fail_threshold=int(settings.get('fail_threshold',3))
    region=(args.region if args.region is not None else settings.get('region','')).upper()
    global PROXY
    port=args.port if args.port is not None else int(settings.get('port',40000))
    if not 1024 <= port <= 65534:ap.error('port must be 1024..65534')
    bind=str(settings.get('bind','127.0.0.1'))
    try:
        if ipaddress.ip_address(bind).version!=4:raise ValueError('IPv4 required')
    except ValueError:ap.error('invalid bind address')
    PROXY=f'{bind}:{port}'
    if region=='AUTO':region=''
    if region and not re.fullmatch('[A-Z]{2}',region):ap.error('invalid country')
    if args.interval<60 or args.wait<20 or args.delay<2:ap.error('interval>=60 wait>=20 delay>=2')
    if not 0<=args.probe_mb<=10 or not 2<=args.fail_threshold<=20:ap.error('probe-mb 0..10, fail-threshold 2..20')
    if args.command=='xray-routing':
        print(json.dumps(xray_routing(args.youtube_instance,args.gemini_instance),indent=2));return 0
    if args.command not in ('status','logs','config','uninstall','stop','xray') and youtube_enabled():
        if args.gemini_check:ap.error('YouTube and Gemini require separate instances; use --no-gemini-check on the YouTube instance')
        if int(settings.get('tunnel_pool',1))!=1:ap.error('YouTube requires --tunnel-pool 1')
        if not ipaddress.ip_address(bind).is_loopback:ap.error('YouTube requires loopback binding')
    if args.command=='status':
        print(json.dumps({'instance':INSTANCE,'youtube_mode':youtube_enabled(),'youtube':youtube_status(POLICY),'region_pool':POLICY.get('region_pool',[]),'min_speed_kib':POLICY.get('min_speed_kib',0),'slow_threshold':POLICY.get('slow_threshold',2),'deny_regions':POLICY.get('deny_regions',['RU']),'impersonate':POLICY.get('impersonate',False),'backend':backend(),'region':region,'state':read_json(STATE,{}) or {},'config':str(CONFIG),'proxy':f'socks5h://{PROXY}','gemini_check':args.gemini_check,'probe_mb':args.probe_mb,'strict_region':args.strict_region,'fail_threshold':args.fail_threshold},indent=2));return 0
    if args.command=='xray':
        print(json.dumps({'tag':'psiphon-out'+('' if INSTANCE==1 else f'-{INSTANCE}'),'protocol':'socks','settings':{'servers':[{'address':bind,'port':port}]}},indent=2));return 0
    if args.command=='config':
        print(json.dumps(view_config(INSTANCE),ensure_ascii=False,indent=2));return 0
    if args.command=='uninstall':uninstall(args.purge_deps);return 0
    if args.command=='logs':
        return subprocess.call(['journalctl','-u',monitor_unit(),'-u',CONTAINER+'.service','-n',args.value or '50','--no-pager'])
    if args.command=='speed':speed_probe(args.probe_mb or 4);return 0
    if args.command in ('start','stop','restart'):
        if args.command!='start':run(['systemctl','stop',monitor_unit()])
        tunnel_action(args.command)
        if args.command!='stop':run(['systemctl','start',monitor_unit()])
        return 0
    if args.command=='check':
        try:
            ip,geo,verdict,speed,reason=evaluate_exit(region,args.gemini_check,args.probe_mb,args.strict_region)
            youtube_observation(ip,geo,verdict,speed,reason)
        except Exception as exc:
            youtube_report('UNKNOWN' if isinstance(exc,GoogleGeoUnknown) else 'DEGRADED',detail=str(exc));raise
        return 2 if reason or speed_reason(speed) else 0
    DATA.mkdir(parents=True,exist_ok=True)
    resume_monitor=False
    if args.command in ('set-region','set-pool','search'):
        active=subprocess.run(['systemctl','is-active','--quiet',monitor_unit()]).returncode==0
        if active:
            run(['systemctl','stop',monitor_unit()],timeout=120)
            resume_monitor=True
    try:
        with (DATA/'lock').open('w') as f:
            try:fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError:raise RuntimeError('Another search/monitor is running')
            if args.region is None:region=(read_json(DATA/'settings.json',{}) or {}).get('region',region)
            if force_rotate:
                pool=rotation_regions(region);region=pool[0]
                save_region(region)
                docker_restart(args.wait)
            if args.command=='set-region':
                set_region(region,args.wait,clear_pool=True)
            elif args.command=='set-pool':
                settings=read_json(DATA/'settings.json',{}) or {}
                if args.region_pool is None:ap.error('set-pool requires --region-pool CC,CC or an empty string')
                settings['region_pool']=countries(args.region_pool)
                atomic_json(DATA/'settings.json',settings)
                POLICY['region_pool']=settings['region_pool']
                if settings['region_pool'] and region not in settings['region_pool']:set_region(settings['region_pool'][0],args.wait)
                log('Region pool saved: '+str(settings['region_pool']))
            elif args.command=='refresh-cache':
                # Explicit operator action with an interruption: stop, export, start.
                # Never claim this happens without a connection interruption.
                if not args.allow_interruption:
                    raise RuntimeError('refresh-cache interrupts Psiphon; repeat with --allow-interruption')
                collect_candidates(region)
                log('Candidate cache refreshed; Psiphon container restarted (tunnel may change)')
            elif args.command=='prepare-pin':
                ip,geo,verdict,speed,reason=evaluate_exit(region,args.gemini_check,args.probe_mb,args.strict_region)
                if reason or speed_reason(speed):raise RuntimeError(f'Exit is not eligible for pin staging: {reason or speed_reason(speed)}')
                state=read_json(STATE,{}) or {}
                diag=connected_id()
                if not state or state.get('ip')!=ip or state.get('diagnostic_id')!=diag:
                    adopt_current(region,args.gemini_check,args.probe_mb,args.strict_region,
                                  observed=(ip,geo,verdict,speed,reason),auto_pin=False)
                if not prepare_current_pin(region,ip,geo,diag):
                    log('No unique cached matching server (or pin already prepared); tunnel untouched')
            elif args.command=='search':
                if int(POLICY.get('tunnel_pool',1))>1:
                    if not force_rotate:save_region(rotation_regions(region)[0]);docker_restart(args.wait)
                else:search(region,args.wait,args.delay,args.gemini_check,args.probe_mb,args.strict_region)
            else:
                loop=pool_monitor if int(POLICY.get('tunnel_pool',1))>1 else monitor
                loop(region,args.interval,args.wait,args.delay,args.gemini_check,args.probe_mb,args.strict_region,args.fail_threshold)
    finally:
        if resume_monitor:run(['systemctl','start',monitor_unit()],timeout=120)
    return 0

if __name__=='__main__':
    try:sys.exit(main())
    except KeyboardInterrupt:log('Stopped');sys.exit(130)
    except Exception as exc:log(f'FATAL: {exc}');sys.exit(1)
PY_MANAGER
chmod 700 "$APP/psiphon_autopin.py"
python3 -m py_compile "$APP/psiphon_autopin.py"
python3 - "$DATA/settings.json" "$REGION" "$SOCKS_PORT" "$GEMINI_CHECK" "$PROBE_MB" "$STRICT_REGION" "$FAIL_THRESHOLD" "$BACKEND" "$REGION_POOL" "$DENY_REGIONS" "$MIN_SPEED" "$SLOW_THRESHOLD" "$IMPERSONATE" "$TUNNEL_POOL" "$INSTANCE" "$INTERVAL" "$WAIT" "$DELAY" "$BIND" "$PUBLISH_HTTP" "$CONNECTION" "$MENU_MODE" "$YOUTUBE_MODE" <<'SETTINGS'
import json,sys
obj={'region':sys.argv[2],'port':int(sys.argv[3]),
     'gemini_check':bool(int(sys.argv[4])),'probe_mb':int(sys.argv[5]),
     'strict_region':bool(int(sys.argv[6])),'fail_threshold':int(sys.argv[7]),
     'backend':sys.argv[8], 'region_pool':sys.argv[9].split(),
     'deny_regions':sys.argv[10].split(),'min_speed_kib':float(sys.argv[11]),
     'slow_threshold':int(sys.argv[12]),'impersonate':bool(int(sys.argv[13])),
     'tunnel_pool':int(sys.argv[14]),'instance':int(sys.argv[15]),
     'interval':int(sys.argv[16]),'wait':int(sys.argv[17]),'delay':int(sys.argv[18]),'bind':sys.argv[19],'publish_http':bool(int(sys.argv[20])),'connection_type':sys.argv[21],'menu_mode':sys.argv[22],'youtube_mode':bool(int(sys.argv[23]))}
with open(sys.argv[1],'w') as f:json.dump(obj,f,indent=2);f.write('\n')
SETTINGS
chmod 600 "$DATA/settings.json"
cp "$dep_tmp/autopin_system.py" "$APP/autopin_system.py"
chmod 700 "$APP/autopin_system.py"
rm -rf "$dep_tmp"; dep_tmp=''
write_menu_module > "$APP/autopin_menu.py"
chmod 700 "$APP/autopin_menu.py"
installer_tmp=$(mktemp "$APP/installer.XXXXXX")
{
    printf '#!/usr/bin/env bash\n# Forcus Auto-Pin offline installer v4.4.0\n'
    declare -f autopin_install_main
    printf '\nautopin_install_main "$@"\n'
} > "$installer_tmp"
chmod 700 "$installer_tmp"
mv -f "$installer_tmp" "$APP/install_psiphon_autopin.sh"
cat > /usr/local/sbin/auto-pin <<'MENU_LAUNCHER'
#!/usr/bin/env bash
# Managed by Forcus Auto-Pin menu
set -euo pipefail
# Prefer the newest installed UI even when the first instance has not been updated yet.
menu_module=$(python3 - <<'SELECT_MENU'
from pathlib import Path
import re
paths=[p for p in Path('/opt').glob('psiphon-autopin*/autopin_menu.py') if p.is_file()]
def key(path):
    try:
        found=re.search(r"^VERSION='([0-9]+\.[0-9]+\.[0-9]+)'$",path.read_text(),re.M)
        return (tuple(map(int,found.group(1).split('.'))) if found else (0,0,0),str(path))
    except OSError:return ((0,0,0),str(path))
if not paths:raise SystemExit('Auto-Pin menu is not installed. Run install_psiphon_autopin.sh first.')
print(max(paths,key=key))
SELECT_MENU
)
exec python3 "$menu_module" "$@"
MENU_LAUNCHER
chmod 755 /usr/local/sbin/auto-pin
python3 - "$APP" "$INSTANCE" <<'MENU_CONNECTION'
import sys
sys.path.insert(0,sys.argv[1])
import autopin_menu as menu
menu.write_connection(menu.load_config(int(sys.argv[2])))
MENU_CONNECTION

EXTRA_FLAGS="--fail-threshold $FAIL_THRESHOLD --probe-mb $PROBE_MB"
if (( GEMINI_CHECK )); then EXTRA_FLAGS="$EXTRA_FLAGS --gemini-check"; fi
if (( STRICT_REGION )); then EXTRA_FLAGS="$EXTRA_FLAGS --strict-region"; fi
TUNNEL_DEP=''
if [[ $BACKEND == vps-psiphon ]]; then TUNNEL_DEP="$CONTAINER.service"; fi
cat > "/etc/systemd/system/$MONITOR" <<EOF
[Unit]
Description=Forcus Psiphon Auto-Pin v4.4.0 server rotation and Google geo monitor
Wants=network-online.target $TUNNEL_DEP
After=network-online.target docker.service $TUNNEL_DEP
Requires=docker.service
PartOf=docker.service
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStart=/usr/bin/python3 $APP/psiphon_autopin.py monitor --instance $INSTANCE --interval $INTERVAL --wait $WAIT --delay $DELAY $EXTRA_FLAGS
Restart=always
RestartSec=30
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
RestrictNamespaces=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
CapabilityBoundingSet=CAP_CHOWN CAP_DAC_OVERRIDE CAP_FOWNER
ReadWritePaths=$DATA $CONF /etc/default
[Install]
WantedBy=multi-user.target
EOF
for alias in "psiphon-autopin$SUFFIX" "$CONTAINER"; do
    cat > "/usr/local/sbin/$alias" <<EOF
#!/usr/bin/env bash
if (( \$# == 0 )); then set -- status; fi
explicit_scope=0
for arg in "\$@"; do
    case "\$arg" in --instance|--instance=*|--all) explicit_scope=1;; esac
done
if (( explicit_scope )); then exec /usr/bin/python3 "$APP/psiphon_autopin.py" "\$@"; fi
if [[ -t 0 && -t 1 ]]; then
    case "\${1:-}" in status|logs|config|xray) exec /usr/bin/python3 "$APP/psiphon_autopin.py" "\$@";; esac
fi
exec /usr/bin/python3 "$APP/psiphon_autopin.py" "\$@" --instance $INSTANCE
EOF
    chmod 755 "/usr/local/sbin/$alias"
done
# Confirm proxy sockets match the configured binding before enabling monitoring.
# A slow Psiphon tunnel need not be ready yet; listener visibility is checked for up to 20s.
for _ in $(seq 1 20); do
    verify_proxy_binding
    if proxy_listeners_ready; then
        echo "[OK] Configured proxies are published on $BIND."
        break
    fi
    sleep 1
done
verify_proxy_binding
# Do not start monitor when listeners have not appeared; fail closed and preserve config for diagnostics.
if ! proxy_listeners_ready; then
    echo '[ERROR] Proxy listeners were not created within 20 seconds; refusing to start monitor.' >&2
    exit 1
fi
systemctl daemon-reload
systemctl enable "$MONITOR"
systemctl restart "$MONITOR"
printf '\n[OK] Forcus Psiphon Auto-Pin v4.4.0 installed\n'
echo '[OK] Existing healthy unpinned exits are retained; targeted pinning remains available.'
echo "[OK] Gemini checks: $GEMINI_CHECK; optional throughput sample: ${PROBE_MB} MiB; strict region: $STRICT_REGION."
echo "[OK] SOCKS5h: $BIND:$SOCKS_PORT (Google and IP checks through proxy)."
echo "[OK] Monitoring every ${INTERVAL}s / unlimited search enabled."
echo "Logs: journalctl -u $MONITOR -f"
echo "Status: psiphon-autopin$SUFFIX status"

echo 'Menu: auto-pin (or psiphon-autopin menu)'
if [[ $CONNECTION == xray ]]; then
    echo "Xray outbound JSON: $DATA/xray-outbound.json"
    cat "$DATA/xray-outbound.json"
    echo 'Add the outbound and routing to Xray; its process must be able to reach the published address.'
fi
autopin_return_to_menu
}
autopin_install_main "$@"
