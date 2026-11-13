                if actual!=expected:
                    raise RuntimeError(f'Wrong server ID: expected {expected}, got {actual}')
                # Do not spend time probing Google for an exit already rejected.
                if exit_ip in seen_exits:
                    log(f'Exit {exit_ip} already rejected in this search; skipping')
                    continue
                first,geo,verdict,speed,reason=evaluate_exit(region,gemini,mb,strict)
                if first!=exit_ip:raise RuntimeError(f'Exit IP changed: {exit_ip} -> {first}')
                if reason:
                    seen_exits.add(first)
                    log(f'Rejected exit {first}: {reason}')
                    continue
                # Recheck IP/geo, without an unnecessary second Gemini request.
                time.sleep(5)
                second,geo2=probe()
                if second!=first or geo2=='RU' or (strict and region and geo2!=region) or connected_id()!=expected:
                    raise RuntimeError(f'Pin verification unstable: {second} Google={geo2}')
                atomic_json(STATE,{'ip':first,'google_region':geo2,'region':region,'diagnostic_id':expected,
                                   'server_ip':server,'gemini':verdict,'speed_kib_s':speed,
                                   'adopted_unpinned':False,'verified_at':dt.datetime.now(dt.timezone.utc).isoformat()})
                log(f'PIN VERIFIED: exit={first} Google={geo2} Gemini={verdict} server={server} ID={expected}')
                return True
            except Exception as exc:
                log(f'Server {server} failed: {exc}')
            time.sleep(delay)
        log('All candidates exhausted. Refreshing discovery and repeating in 60s...')
        clear_target(region)
        try:docker_restart(wait)
        except Exception as e:log(f'Discovery connection warning: {e}')
        time.sleep(60)
        # After a full cycle, the same exit could have been reclassified by Google.
        seen_exits.clear()

def monitor(region,interval,wait,delay,gemini=False,mb=0,strict=False,threshold=3):
    log(f'Monitor v3.4: region={region or "AUTO"} interval={interval}s Gemini={gemini} speedMB={mb}')
    failures=0
    while True:
        try:
            ip,geo,verdict,speed,reason=evaluate_exit(region,gemini,mb,strict)
            state=read_json(STATE,{}) or {}
            config=read_json(CONFIG,{}) or {}
            diag=connected_id()
            changed=bool(state) and (ip!=state.get('ip') or diag!=state.get('diagnostic_id'))
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
                log(f'Healthy exit unchanged: {ip} Google={geo} Gemini={verdict}; '
                    + ('adopted (not pinned)' if state.get('adopted_unpinned') else 'pinned'))
        except Exception as exc:
            failures+=1
            log(f'UNKNOWN/OUTAGE {failures}/{threshold}: {exc}; no RU inference')
            if failures>=threshold:
                log('Consecutive failures reached threshold; recovering connection')
                try:
                    docker_restart(wait)
                    # Only run rotation if the restarted tunnel is still unusable.
                    ip,geo,verdict,_,reason=evaluate_exit(region,gemini,0,strict)
                    if reason:
                        search(region,wait,delay,gemini,mb,strict)
                    else:
                        log(f'Recovered without full search: {ip} Google={geo} Gemini={verdict}')
                except Exception as e:
                    log(f'Recovery incomplete: {e}; defer next attempt')
                failures=0
        time.sleep(interval)

def main():
    ap=argparse.ArgumentParser(description='Psiphon Auto-Pin v3.4')
    ap.add_argument('command',choices=['check','search','monitor','status'])
    ap.add_argument('--region',default=None)
    ap.add_argument('--port',type=int,default=None)
    ap.add_argument('--interval',type=int,default=3600)
    ap.add_argument('--wait',type=int,default=75)
    ap.add_argument('--delay',type=int,default=12)
    ap.add_argument('--gemini-check',action='store_true',default=None)
    ap.add_argument('--no-gemini-check',dest='gemini_check',action='store_false')
    ap.add_argument('--probe-mb',type=int,default=None)
    ap.add_argument('--strict-region',action='store_true',default=None)
    ap.add_argument('--no-strict-region',dest='strict_region',action='store_false')
    ap.add_argument('--fail-threshold',type=int,default=None)
    args=ap.parse_args()
    settings=read_json(DATA/'settings.json',{}) or {}
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
    PROXY=f'127.0.0.1:{port}'
    if region=='AUTO':region=''
    if region and not re.fullmatch('[A-Z]{2}',region):ap.error('invalid country')
    if args.interval<60 or args.wait<20 or args.delay<2:ap.error('interval>=60 wait>=20 delay>=2')
    if not 0<=args.probe_mb<=10 or not 2<=args.fail_threshold<=20:ap.error('probe-mb 0..10, fail-threshold 2..20')
    if args.command=='status':
        print(json.dumps({'region':region,'state':read_json(STATE,{}) or {},'config':str(CONFIG),'proxy':f'socks5h://{PROXY}','gemini_check':args.gemini_check,'probe_mb':args.probe_mb,'strict_region':args.strict_region,'fail_threshold':args.fail_threshold},indent=2));return 0
    if args.command=='check':
        _,geo=probe()
        verdict=gemini_verdict(args.gemini_check)
        return 2 if geo=='RU' or verdict=='REFUSED' else 0
