#!/usr/bin/env bash
# Forcus Psiphon Auto-Pin Manager v4.1.2
# Author: https://github.com/Forcus356
# Ubuntu/Debian x86_64
autopin_install_main() {
set -Eeuo pipefail
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
import copy
import datetime as dt
from dataclasses import dataclass
from decimal import Decimal, DecimalException
import ipaddress
import json
import os
import re
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unicodedata

VERSION='4.1.2'
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
)
EASY_KEYS=('region','connection_type','gemini_check','port','interval')
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
        wait=75,delay=12,impersonate=False,backend='auto',menu_mode='easy')

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

def installer_for(instance,fallback=None):
    candidates=[paths(instance)['app']/'install_psiphon_autopin.sh']
    if fallback:candidates.append(Path(fallback))
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
        ('impersonate','--impersonate','--no-impersonate')]:
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
        self.terminal=terminal;self.instance=instance;self.installer=installer;self.emit_args=emit_args
        self.config=load_config(instance)
        self.style=ConsoleStyle(terminal);self._status_cache=None
    def say(self,text=''):print(text,file=self.terminal,flush=True)
    def ask(self,prompt):
        self.terminal.write(prompt);self.terminal.flush();answer=self.terminal.readline()
        if not answer:raise EOFError
        return answer.strip()
    def confirm(self,text):return self.ask(text+' [да/нет, по умолчанию нет]: ').lower() in TRUE
    def panel(self,title,sections):
        self.say('\n'+self.style.box(title,sections))
    def footer(self):
        saved=load_config(self.instance);installed=paths(self.instance)['manager'].is_file()
        state=read_state(self.instance)
        key=(self.instance,saved['backend'])
        if installed:
            if self._status_cache is None or self._status_cache[0]!=key or time.monotonic()-self._status_cache[1]>2:
                self._status_cache=(key,time.monotonic(),runtime_status(self.instance,saved['backend']))
            status=self._status_cache[2]
        else:status={name:{'state':'not-found','autostart':'unknown'} for name in ('tunnel','monitor')}
        tunnel,tone=status_label(status['tunnel']['state']);monitor,monitor_tone=status_label(status['monitor']['state'])
        combined='green' if tone==monitor_tone=='green' else 'red' if 'red' in (tone,monitor_tone) else 'yellow'
        self.say(self.style.info('Туннель: '+tunnel+'  ·  Монитор: '+monitor,combined))
        if installed:
            auto='монитор '+autostart_label(status['monitor']['autostart'])
            if saved['backend']!='console':auto='туннель '+autostart_label(status['tunnel']['autostart'])+' / '+auto
            self.say(self.style.info('Автозапуск: '+auto))
        mode='пул, задано '+str(saved['tunnel_pool']) if saved['tunnel_pool']>1 else 'PIN подготовлен' if state.get('pin_prepared') else 'PIN закреплён' if state.get('diagnostic_id') and state.get('adopted_unpinned') is False else 'один туннель'
        self.say(self.style.info('Регион: '+(saved['region'] or 'AUTO')+'  ·  Режим: '+mode))
        endpoint=saved['bind']+':'+str(saved['port'])
        self.say(self.style.info('SOCKS5: '+endpoint+'  ·  HTTP: '+(str(saved['port']+1) if saved['publish_http'] else 'выключен')))
        if state:
            self.say(self.style.info('Последний IP: '+str(state.get('ip') or 'нет данных')+'  ·  Google: '+str(state.get('google_region') or 'неизвестно')))
        gemini=str(state.get('gemini') or 'нет проверки') if saved['gemini_check'] else 'выключен'
        self.say(self.style.info('Gemini: '+gemini,'green' if gemini=='SERVING' else 'red' if gemini in ('REFUSED','CAPTCHA') else 'normal'))
        if state.get('verified_at'):
            verified=str(state['verified_at'])
            try:verified=dt.datetime.fromisoformat(verified.replace('Z','+00:00')).strftime('%d.%m.%Y %H:%M:%S %Z').strip()
            except ValueError:pass
            self.say(self.style.info('Последняя проверка: '+verified))
        self.say(self.style.info('Watchdog: интервал '+watchdog_period(saved['interval'])))
        output='SOCKS5' if saved['connection_type']=='socks5' else 'Xray JSON'
        self.say(self.style.info('Скрипт: v'+VERSION+'  ·  Формат: '+output,'cyan'))
        dirty=any(self.config.get(f.key)!=saved.get(f.key) for f in FIELDS)
        if dirty:self.say(self.style.info('Есть изменения, ещё не применены.','yellow'))
        elif not installed:self.say(self.style.info('Экземпляр ещё не установлен. Выберите настройки.','yellow'))
        self.say()
    def edit(self,mode):
        self.config['menu_mode']=mode
        fields=[f for f in FIELDS if mode=='advanced' or f.key in EASY_KEYS]
        while True:
            groups=[]
            headings=({0:'ОСНОВНОЕ',4:'WATCHDOG'} if mode=='easy' else {0:'ОСНОВНОЕ',4:'СЕТЬ',6:'СТРАНЫ И ТУННЕЛИ',10:'СКОРОСТЬ',13:'МОНИТОРИНГ',17:'СОВМЕСТИМОСТЬ'})
            for index,field in enumerate(fields):
                if index in headings:groups.append((headings[index],[]))
                groups[-1][1].append(f'{index+1:2}. {field.label}: {display(field,self.config[field.key])}')
            groups.append(('', ['a. Просмотреть и применить','0. Назад без применения']))
            self.panel(f'{mode.title()} Mode · экземпляр {self.instance}',groups)
            self.footer()
            answer=self.ask('Выбор: ').lower()
            if answer=='0':return False
            if answer in ('a','а'):
                if self.apply():return True
                continue
            try:
                index=int(answer)
                if not 1<=index<=len(fields):raise ValueError
                field=fields[index-1];self.say(field.help)
                if field.choices:self.say(' / '.join(f'{n}. {v}' for n,v in enumerate(field.choices,1)))
                text=self.ask(f'{field.label} [{display(field,self.config[field.key])}], Enter — оставить: ')
                if text:
                    value=parse_field(field,text);self.config[field.key]=value
                    if field.key=='region' and self.config['region_pool'] and value not in self.config['region_pool']:
                        self.config['region_pool']=[];self.say('Пул стран очищен: новая страна вне прежнего пула.')
                    if field.key=='region_pool' and value and self.config['region'] not in value:
                        self.config['region']=value[0];self.say('Выбрана первая страна из пула: '+value[0])
            except (ValueError,TypeError) as exc:self.say('Ошибка: '+(str(exc) or 'выберите номер из меню'))
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
            result=subprocess.run(['bash',str(installer),*args])
            if result.returncode:
                self.say(f'Установщик завершился с кодом {result.returncode}; сохранение новых настроек не подтверждено. Проверьте журналы.')
                return False
            self.config=load_config(self.instance);self._status_cache=None
            self.show_connection();return True
        except (OSError,RuntimeError) as exc:self.say('Ошибка применения: '+str(exc));return False
    def show_connection(self):
        value=connection(self.config);self.say('\nГотово. Подключение:')
        self.say(value['uri'] if value['type']=='socks5' else json.dumps(value['outbound'],ensure_ascii=False,indent=2))
        self.say('Настройки: '+str(paths(self.instance)['data']/'settings.json'))
        if value['type']=='xray':
            self.say('JSON: '+str(paths(self.instance)['data']/'xray-outbound.json'))
            self.say('Добавьте outbound и маршрутизацию в Xray. Его процесс должен иметь доступ к указанному адресу VPS.')
    def select_instance(self):
        self.say('Установлены: '+(', '.join(map(str,discover())) or 'нет'))
        try:
            value=valid_instance(self.ask('Номер экземпляра 1–99 (существующий или новый): '))
            config=load_config(value)
            self.instance=value;self.config=config;self._status_cache=None
        except (ValueError,OSError) as exc:self.say('Ошибка: '+str(exc))
    def manage(self):
        manager=paths(self.instance)['manager']
        if not manager.is_file():self.say('Этот экземпляр ещё не установлен. Выберите Easy или Advanced.');return False
        actions=[('Статус','status'),('Проверить соединение','check'),('Запустить','start'),
            ('Остановить','stop'),('Перезапустить','restart'),('Сменить сервер / ротация','rotate'),
            ('Поиск сервера / PIN','search'),('Показать журналы','logs'),('Измерить скорость','speed'),('Показать Xray JSON','xray'),
            ('Подготовить PIN','prepare-pin'),('Обновить кэш серверов','refresh-cache'),('Удалить этот экземпляр','uninstall')]
        self.panel('Управление · экземпляр '+str(self.instance),[
            ('СОСТОЯНИЕ И СЛУЖБЫ',[f'{index+1:2}. {label}' for index,(label,_) in enumerate(actions) if index<5]),
            ('ДИАГНОСТИКА И СЕРВЕРЫ',[f'{index+1:2}. {label}' for index,(label,_) in enumerate(actions) if 5<=index<12]),
            ('', ['13. Удалить этот экземпляр','0. Назад'])])
        self.footer();answer=self.ask('Выбор: ')
        if answer=='0':return False
        try:
            index=int(answer)
            if not 1<=index<=len(actions):raise ValueError
        except ValueError:self.say('Выберите номер из меню.');return False
        label,command=actions[index-1];extra=[]
        if command=='logs':
            raw=self.ask('Строк журнала [50]: ')
            try:count=int(raw or '50');assert 1<=count<=10000
            except (ValueError,AssertionError):self.say('Нужно число 1–10000.');return False
            extra=[str(count)]
        if command=='refresh-cache':extra=['--allow-interruption']
        if command in ('stop','restart','rotate','search','refresh-cache','uninstall'):
            warning='Удалятся службы, контейнер и данные только выбранного экземпляра.' if command=='uninstall' else 'Это действие может прервать соединения выбранного экземпляра.'
            self.say(warning)
            if not self.confirm(label+'?'):return False
        try:
            result=subprocess.run([sys.executable,str(manager),command,*extra,'--instance',str(self.instance)])
            self._status_cache=None
            self.say('Код завершения: '+str(result.returncode))
            return command=='uninstall' and result.returncode==0
        except OSError as exc:self.say('Ошибка запуска: '+str(exc));return False
    def run(self):
        while True:
            self.panel(f'Forcus Auto-Pin {VERSION} · экземпляр {self.instance}',[
                ('НАСТРОЙКА',['1. Easy Mode — основные настройки','2. Advanced Mode — все настройки']),
                ('ОБСЛУЖИВАНИЕ',['3. Управление и диагностика','4. Выбрать / создать экземпляр']),
                ('', ['0. Выход'])])
            self.footer()
            answer=self.ask('Выбор [Enter — '+self.config['menu_mode'].title()+']: ')
            if answer=='':answer='1' if self.config['menu_mode']=='easy' else '2'
            if answer=='0':return 0
            if answer in ('1','2'):
                applied=self.edit('easy' if answer=='1' else 'advanced')
                if applied and self.emit_args:return 0
            elif answer=='3':
                if self.manage():return 0
            elif answer=='4':self.select_instance()
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
    parser.add_argument('--emit-args',type=Path,help=argparse.SUPPRESS)
    args=parser.parse_args(argv)
    if os.geteuid()!=0:print('Запустите меню от root: sudo auto-pin',file=sys.stderr);return 1
    try:
        instance=valid_instance(args.instance) if args.instance is not None else (discover() or [1])[0]
        with open('/dev/tty','r',encoding='utf-8') as reader, open('/dev/tty','w',encoding='utf-8',buffering=1) as writer:
            return Menu(TerminalIO(reader,writer),instance,args.installer,args.emit_args).run()
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
    menu_rc=0
    python3 "$menu_tmp/autopin_menu.py" "${menu_options[@]}" --emit-args "$menu_tmp/args.json" || menu_rc=$?
    if (( menu_rc )); then rm -rf "$menu_tmp"; return "$menu_rc"; fi
    if [[ ! -s $menu_tmp/args.json ]]; then rm -rf "$menu_tmp"; return 0; fi
    mapfile -d '' -t menu_argv < <(python3 - "$menu_tmp/args.json" <<'MENU_ARGS'
import json,sys
for arg in json.load(open(sys.argv[1])):
    sys.stdout.buffer.write(arg.encode()+b'\0')
MENU_ARGS
)
    rm -rf "$menu_tmp"
    set -- "${menu_argv[@]}"
fi
export DEBIAN_FRONTEND=noninteractive
ROOT=/opt/vps-psiphon; CONF="$ROOT/config"; APP=/opt/psiphon-autopin
DATA=/var/lib/psiphon-autopin; CONTAINER=vps-psiphon
CONNECTION=socks5; MENU_MODE=easy
INSTANCE=1; REGION_POOL=''; DENY_REGIONS='RU BY IR SY CU KP CN VE'; MIN_SPEED=800; SLOW_THRESHOLD=2; IMPERSONATE=0; TUNNEL_POOL=1; BIND=127.0.0.1; PUBLISH_HTTP=1
REGION=''; INTERVAL=300; WAIT=75; DELAY=12; SOCKS_PORT=''
GEMINI_CHECK=1; PROBE_MB=4; FAIL_THRESHOLD=3; STRICT_REGION=0
PORT_EXPLICIT=0; BACKEND=auto; REGION_EXPLICIT=0
declare -A POLICY_SET=()
while (($#)); do
    case "$1" in
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
        --help) printf '%b\n' 'Interactive: install_psiphon_autopin.sh [--menu [--instance N]]; reopen: auto-pin.\nUsage: install_psiphon_autopin.sh [--connection socks5|xray] [--bind 127.0.0.1] [--no-http] [--instance 1..99] [--region-pool NL,DE] [--min-speed 800] [--slow-threshold 2] [--deny-regions "RU BY IR SY CU KP CN VE"] [--impersonate] [--tunnel-pool 1..32] [--backend auto|console|vps-psiphon] [--region DE|AUTO] [--port 40000] [--interval 300] [--wait 75] [--delay 12] [--gemini-check] [--probe-mb 0..10] [--strict-region] [--fail-threshold 3]'; exit 0 ;;
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
    elif docker inspect -f '{{.Config.Image}}' "$CONTAINER" 2>/dev/null | grep -qx 'local-psiphon-console:latest'; then
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
for key,default in [('region_pool',[]),('deny_regions',['RU','BY','IR','SY','CU','KP','CN','VE']),('min_speed_kib',800),('slow_threshold',2),('tunnel_pool',1),('probe_mb',4),('interval',300),('wait',75),('delay',12),('fail_threshold',3),('impersonate',False),('gemini_check',True),('bind','127.0.0.1'),('publish_http',True),('strict_region',False),('connection_type','socks5'),('menu_mode','easy')]:
    v=s.get(key,default)
    print(' '.join(v) if isinstance(v,list) else v if isinstance(v,str) else int(v))
SAVED_POLICY
)
    fields=(region_pool deny_regions min_speed_kib slow_threshold tunnel_pool probe_mb interval wait delay fail_threshold impersonate gemini_check bind publish_http strict_region connection_type menu_mode)
    variables=(REGION_POOL DENY_REGIONS MIN_SPEED SLOW_THRESHOLD TUNNEL_POOL PROBE_MB INTERVAL WAIT DELAY FAIL_THRESHOLD IMPERSONATE GEMINI_CHECK BIND PUBLISH_HTTP STRICT_REGION CONNECTION MENU_MODE)
    for index in "${!fields[@]}"; do
        if [[ -z ${POLICY_SET[${fields[$index]}]:-} ]]; then printf -v "${variables[$index]}" '%s' "${saved_policy[$index]}"; fi
    done
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
mkdir -p "$ROOT" "$CONF" "$APP" "$DATA"
chmod 700 "$DATA"
echo "[INFO] Region=${REGION:-AUTO}; SOCKS5=127.0.0.1:$SOCKS_PORT; manager v4.1.2; backend=$BACKEND"

# Monitor is stopped after installation ownership checks below.

# Install only missing packages. Never replace Docker CE with Ubuntu docker.io.
PACKAGES=()
command -v curl >/dev/null 2>&1 || PACKAGES+=(curl)
command -v jq >/dev/null 2>&1 || PACKAGES+=(jq)
command -v python3 >/dev/null 2>&1 || PACKAGES+=(python3)
command -v column >/dev/null 2>&1 || PACKAGES+=(bsdextrautils)
command -v go >/dev/null 2>&1 || PACKAGES+=(golang-go)
command -v ss >/dev/null 2>&1 || PACKAGES+=(iproute2)
if ((${#PACKAGES[@]})); then
    apt-get update
    apt-get install -y ca-certificates "${PACKAGES[@]}"
fi
if ! command -v docker >/dev/null 2>&1; then
    apt-get update
    if apt-cache show docker-ce 2>/dev/null | grep -q '^Package: docker-ce$'; then
        apt-get install -y docker-ce docker-ce-cli containerd.io
    else
        apt-get install -y docker.io
    fi
else
    echo "[OK] Using existing $(docker --version)"
fi
systemctl enable --now docker
if ! docker info >/dev/null 2>&1; then
    echo '[ERROR] Docker daemon not responding' >&2; exit 1
fi

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
        python3 - "$ENVF" "$CONTAINER" "$CONF" <<'VALIDATE_VPS'
import shlex,sys
values={}
for line in open(sys.argv[1]):
    if '=' in line and not line.lstrip().startswith('#'):
        key,value=line.rstrip().split('=',1)
        parts=shlex.split(value,comments=True)
        values[key]=' '.join(parts)
for key,want in {'NAME':sys.argv[2],'CONF_DIR':sys.argv[3],
                 'IMAGE':'swarupsengupta2007/psiphon:latest'}.items():
    if values.get(key,want)!=want:raise SystemExit(f'Unsupported vps-psiphon {key}; no services changed')
VALIDATE_VPS
        if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
            [[ $(docker inspect -f '{{.Config.Image}}' "$CONTAINER") == swarupsengupta2007/psiphon:latest &&
               $(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}' "$CONTAINER") == "$CONF" ]] || {
                echo '[ERROR] Foreign vps-psiphon container; no services changed.' >&2; exit 1;
            }
        fi
    fi
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
        docker pull swarupsengupta2007/psiphon:latest
        docker run --rm --entrypoint cat swarupsengupta2007/psiphon:latest /etc/psiphon/psiphon.config > "$CONF/psiphon.config"
        chown 1000:1000 "$CONF/psiphon.config"; chmod 600 "$CONF/psiphon.config"
        cat > "$ENVF" <<EOF
IMAGE=swarupsengupta2007/psiphon:latest
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
    python3 - "$ENVF" "$REGION" "$SOCKS_PORT" "$HTTP_PORT" "$CONTAINER" "$CONF" "$TUNNEL_POOL" "$BIND" "$PUBLISH_HTTP" <<'VPS_ENV'
from pathlib import Path
import sys
p=Path(sys.argv[1]);region,socks,http,name,conf,pool,bind,publish=sys.argv[2:]
updates={'NAME':name,'CONF_DIR':conf,
         'IMAGE':'swarupsengupta2007/psiphon:latest',
         'BIND':bind,'SOCKS_PORT':socks,'HTTP_PORT':http,
         'PUBLISH_HTTP':publish,'EGRESS_REGION':region,'TUNNEL_POOL_SIZE':pool,
         'REGION_POOL':"''"}
lines=p.read_text().splitlines()
lines=[line for line in lines if line.split('=',1)[0] not in updates]
p.write_text('\n'.join(lines+[f'{k}={v}' for k,v in updates.items()])+'\n')
VPS_ENV
    sed "s/@P@/$CONTAINER/g" > "$RUNNER" <<'VPS_RUN'
#!/usr/bin/env bash
# Managed by Forcus Auto-Pin. Host ports in env; fixed ports inside Docker.
set -euo pipefail
. /etc/default/@P@
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
exec docker run --rm --name "$NAME" \
    "${ports[@]}" \
    -e PUID=1000 -e PGID=1000 -e SOCKS_PORT=1080 -e HTTP_PORT=8080 \
    -e DEVICE_REGION="${DEVICE_REGION:-}" -e EGRESS_REGION="${EGRESS_REGION:-}" \
    -v "${CONF_DIR}:/config" "$IMAGE"
VPS_RUN
    chmod 755 "$RUNNER"
    if [[ ! -s $CONF/psiphon.config ]]; then
        docker run --rm --entrypoint cat swarupsengupta2007/psiphon:latest /etc/psiphon/psiphon.config > "$CONF/psiphon.config"
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
[Service]
ExecStart=$RUNNER
ExecStop=/usr/bin/docker stop -t 10 $CONTAINER
Restart=always
RestartSec=10
TimeoutStartSec=0
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$CONTAINER.service"
    systemctl start "$CONTAINER.service"
else
if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    [[ -f $CONF/psiphon.config ]] || { echo "Missing $CONF/psiphon.config" >&2; exit 1; }
    # Never adopt a foreign container with the same name: legacy installations
    # commonly publish 40000:1080 and ignore the new port in the JSON.
    IMAGE=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER")
    NETMODE=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER")
    MOUNT_OK=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}' "$CONTAINER")
    if [[ "$IMAGE" != 'local-psiphon-console:latest' || "$NETMODE" != 'host' || "$MOUNT_OK" != "$CONF" ]]; then
        echo "[ERROR] Existing $CONTAINER is not ours (image=$IMAGE network=$NETMODE mount=$MOUNT_OK)." >&2
        echo '[ERROR] Stop legacy psiphon services and migrate explicitly; no container was replaced.' >&2
        exit 1
    fi
    systemctl stop "$MONITOR" 2>/dev/null || true
    echo '[INFO] Existing compatible Psiphon container preserved.'
    CURRENT_SOCKS_PORT=$(python3 - "$CONF/psiphon.config" <<'PYOLDPORT'
import json,sys
print(json.load(open(sys.argv[1])).get('LocalSocksProxyPort',40000))
PYOLDPORT
)
    if [[ "$CURRENT_SOCKS_PORT" != "$SOCKS_PORT" ]]; then
        if proxy_port_occupied; then
            echo "[ERROR] New SOCKS/HTTP port $SOCKS_PORT/$HTTP_PORT occupied" >&2; exit 1
        fi
    fi
    docker start "$CONTAINER" >/dev/null || true
else
    [[ ! -e $CONF/psiphon.config ]] || { echo 'Config exists but container missing; refusing overwrite.' >&2; exit 1; }
    if proxy_port_occupied; then
        echo "SOCKS/HTTP port $SOCKS_PORT/$HTTP_PORT already occupied" >&2; exit 1
    fi
    systemctl stop "$MONITOR" 2>/dev/null || true
    echo '[INFO] Bootstrapping Psiphon...'
    docker pull swarupsengupta2007/psiphon:latest
    docker run --rm --entrypoint cat swarupsengupta2007/psiphon:latest /etc/psiphon/psiphon.config > "$CONF/psiphon.config"
    chmod 600 "$CONF/psiphon.config"
    python3 - "$CONF/psiphon.config" "$REGION" "$SOCKS_PORT" "$HTTP_PORT" <<'CONFIG_INIT'
import json,sys
p,r,socks,http=sys.argv[1:]
c=json.load(open(p))
c.update(EgressRegion=r,ListenInterface='lo',LocalSocksProxyPort=int(socks),LocalHttpProxyPort=int(http),TunnelPoolSize=1,EmitDiagnosticNotices=True,DisableReplay=True)
c.pop('LocalSocksProxyListenAddress',None)
c.pop('LocalHttpProxyListenAddress',None)
with open(p,'w') as f: json.dump(c,f,indent=2); f.write('\n')
CONFIG_INIT
    tree=$(mktemp)
    curl --fail --location --silent --show-error --retry 3 'https://api.github.com/repos/Psiphon-Labs/psiphon-tunnel-core-binaries/git/trees/master?recursive=1' -o "$tree"
    path=$(python3 - "$tree" <<'PICK_BINARY'
import json,sys
rows=json.load(open(sys.argv[1]))['tree']
m=[v['path'] for v in rows if v['type']=='blob' and v['path'].startswith('linux/') and any(x in v['path'].lower() for x in ('amd64','x86_64')) and any(x in v['path'].lower() for x in ('consoleclient','psiphon-tunnel-core'))]
if len(m)!=1: raise SystemExit('Expected one official executable: '+str(m))
print(m[0])
PICK_BINARY
)
    rm -f "$tree"
    curl --fail --location --silent --show-error --retry 3 "https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/$path" -o "$ROOT/ConsoleClient"
    chmod 755 "$ROOT/ConsoleClient"
    cat > "$ROOT/Dockerfile" <<'DOCKERFILE'
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY ConsoleClient /usr/local/bin/ConsoleClient
WORKDIR /config
CMD ["/usr/local/bin/ConsoleClient", "-config", "/config/psiphon.config", "-dataRootDirectory", "/config"]
DOCKERFILE
    docker build -t local-psiphon-console:latest "$ROOT"
    docker run -d --name "$CONTAINER" --restart unless-stopped --network host -v "$CONF:/config" local-psiphon-console:latest >/dev/null
    echo '[OK] Created Psiphon container.'
fi

# Update the region on re-install. Invalidate stale pin state when region changes.
SYNC_CHANGED=$(python3 - "$CONF/psiphon.config" "$DATA/state.json" "$REGION" "$SOCKS_PORT" "$HTTP_PORT" <<'SYNC_REGION'
import json,sys,os,shutil,datetime
p,s,r,socks,http=sys.argv[1:];c=json.load(open(p))
routing_changed=(c.get('EgressRegion','')!=r or c.get('LocalSocksProxyPort')!=int(socks) or c.get('LocalHttpProxyPort')!=int(http))
security_changed=(c.get('ListenInterface')!='lo' or 'LocalSocksProxyListenAddress' in c or 'LocalHttpProxyListenAddress' in c)
if routing_changed or security_changed:
    shutil.copy2(p,p+'.before-update-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
    c['EgressRegion']=r
    c['ListenInterface']='lo'
    c['LocalSocksProxyPort']=int(socks)
    c['LocalHttpProxyPort']=int(http)
    c.pop('LocalSocksProxyListenAddress',None)
    c.pop('LocalHttpProxyListenAddress',None)
    if routing_changed:
        c.pop('TargetServerEntry',None)
        if os.path.isfile(s):os.unlink(s)
    with open(p,'w') as f:json.dump(c,f,indent=2);f.write('\n')
    print('security_changed' if security_changed and not routing_changed else 'changed')
SYNC_REGION
)
if [[ -n "$SYNC_CHANGED" ]]; then
    echo "[INFO] Region, port or loopback security settings changed: restarting Psiphon"
    docker restart "$CONTAINER" >/dev/null
fi

fi # console backend

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
if [[ -n $POOL_CHANGED ]]; then
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
        echo "[SECURITY ERROR] Psiphon proxy is listening outside localhost:" >&2
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
    docker pull swarupsengupta2007/psiphon:latest
    template=$(mktemp)
    docker run --rm --entrypoint cat swarupsengupta2007/psiphon:latest /etc/psiphon/psiphon.config > "$template"
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
    ( cd "$builddir" && go mod init foc.us/psiphon-exporter >/dev/null && go get go.etcd.io/bbolt@v1.3.11 && go build -o "$APP/psiphon-server-export" . )
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
PY_GEMINI
chmod 700 "$APP/gemini_probe.py"
python3 -m py_compile "$APP/gemini_probe.py"

cat > "$APP/psiphon_autopin.py" <<'PY_MANAGER'
#!/usr/bin/env python3
"""Forcus Psiphon Auto-Pin v4.1.2: controlled server selection + SOCKS-only geolocation."""
import argparse
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
    if not POLICY.get('legacy_geo_fallback',False):raise RuntimeError('Google country UNKNOWN')
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
    if len(geo)!=1 or not re.fullmatch('[A-Z]{2}',geo[0]):raise RuntimeError(f'Google region UNKNOWN: {geo}')
    return geo[0]

def probe():
    first=socks_ip();country=google_region();last=socks_ip()
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
    denied=POLICY.get('deny_regions',['RU'])
    reason=(f'Google={geo}' if geo in denied else 'Gemini REFUSED' if verdict=='REFUSED' else
            'Gemini CAPTCHA' if verdict=='CAPTCHA' else
            f'Google={geo} != requested {region}' if strict and region and geo!=region else '')
    return ip,geo,verdict,speed,reason

def adopt_current(region,gemini,mb,strict,observed=None):
    """Keep a healthy tunnel; recover an existing target only against the cached DB entry."""
    config=read_json(CONFIG,{}) or {}
    ip,geo,verdict,speed,reason = observed if observed is not None else evaluate_exit(region,gemini,mb,strict)
    if reason or speed_reason(speed):return False
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
        log(f'RECOVERED VERIFIED PIN: exit={ip} Google={geo} Gemini={verdict} '
            f'server={row["server_ip"]} ID={diag}; no restart')
        return True
    atomic_json(STATE,{'region':region,'ip':ip,'google_region':geo,
        'diagnostic_id':diag,'server_ip':None,'gemini':verdict,
        'speed_kib_s':speed,'adopted_unpinned':True,
        'verified_at':dt.datetime.now(dt.timezone.utc).isoformat()})
    log(f'ADOPTED HEALTHY exit={ip} Google={geo} Gemini={verdict} ID={diag}; no restart (not targeted pin)')
    prepare_current_pin(region,ip,geo,diag)
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
    if not reason and ip==state.get('ip') and diag==state.get('diagnostic_id'):
        state.update(pin_prepared=False,adopted_unpinned=False,
                     verified_at=dt.datetime.now(dt.timezone.utc).isoformat())
        state.pop('prepared_container_started_at',None)
        atomic_json(STATE,state)
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

def collect_candidates(region):
    # BoltDB is read only with the container stopped; always start it again.
    log('Exporting distinct server entries from read-only BoltDB...')
    tunnel_action('stop')
    try:
        raw=run([str(BASE/'psiphon-server-export'),str(db_path()),region],timeout=120)
        rows=[json.loads(line) for line in raw.splitlines() if line.strip()]
        rows=[v for v in rows if v.get('server_ip') and v.get('diagnostic') and v.get('encoded')]
        if not rows:raise RuntimeError(f'No known servers in region {region or "AUTO"}')
        cache_candidates(rows,region)
        log(f'Loaded {len(rows)} distinct servers')
        return rows
    finally:
        tunnel_action('start')

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
    if ip==state['ip'] and not reason and not speed_reason(speed) and diag==state.get('diagnostic_id'):
        log(f'Existing pin healthy: {ip}, {geo}, server={diag}')
        return True
    return False

def search(region,wait,delay,gemini=False,mb=0,strict=False):
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
                    log(f'Rejected exit {first}: {reason}')
                    continue
                # Recheck IP/geo, without an unnecessary second Gemini request.
                time.sleep(5)
                second,geo2=probe()
                if second!=first or geo2 in POLICY.get('deny_regions',['RU']) or (strict and region and geo2!=region) or connected_id()!=expected:
                    raise RuntimeError(f'Pin verification unstable: {second} Google={geo2}')
                atomic_json(STATE,{'ip':first,'google_region':geo2,'region':region,'diagnostic_id':expected,
                                   'server_ip':server,'gemini':verdict,'speed_kib_s':speed,
                                   'adopted_unpinned':False,'verified_at':dt.datetime.now(dt.timezone.utc).isoformat()})
                remember_pin(candidate,region)
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
    log(f'Monitor v4.1: region={region or "AUTO"} interval={interval}s Gemini={gemini} speedMB={mb}')
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
                if state.get('adopted_unpinned') and not config.get('TargetServerEntry'):
                    prepare_current_pin(region,ip,geo,diag)
                log(f'Healthy exit unchanged: {ip} Google={geo} Gemini={verdict}; '
                    + ('adopted (not pinned)' if state.get('adopted_unpinned') else 'pinned'))
        except Exception as exc:
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

def uninstall():
    """Remove just this instance; retain migration backups and any image used by others."""
    if os.geteuid()!=0:raise RuntimeError('Run as root')
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
    print(f'Removed instance {INSTANCE}; backups under /var/backups/psiphon-autopin are retained')

def main():
    ap=argparse.ArgumentParser(description='Psiphon Auto-Pin v4.1')
    ap.add_argument('command',choices=['menu','check','search','monitor','status','refresh-cache','prepare-pin','set-region','set-pool','region','pool','rotate','start','stop','restart','logs','speed','uninstall','xray'])
    ap.add_argument('value',nargs='?')
    ap.add_argument('--instance',type=int,default=1)
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
    force_rotate=(args.command=='rotate')
    if not 1<=args.instance<=99:ap.error('instance must be 1..99')
    if args.instance!=1:configure_instance(args.instance)
    if args.command=='menu':
        return subprocess.call([sys.executable,str(BASE/'autopin_menu.py'),'--instance',str(args.instance)])
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
    if args.command=='status':
        print(json.dumps({'instance':INSTANCE,'region_pool':POLICY.get('region_pool',[]),'min_speed_kib':POLICY.get('min_speed_kib',0),'slow_threshold':POLICY.get('slow_threshold',2),'deny_regions':POLICY.get('deny_regions',['RU']),'impersonate':POLICY.get('impersonate',False),'backend':backend(),'region':region,'state':read_json(STATE,{}) or {},'config':str(CONFIG),'proxy':f'socks5h://{PROXY}','gemini_check':args.gemini_check,'probe_mb':args.probe_mb,'strict_region':args.strict_region,'fail_threshold':args.fail_threshold},indent=2));return 0
    if args.command=='xray':
        print(json.dumps({'tag':'psiphon-out'+('' if INSTANCE==1 else f'-{INSTANCE}'),'protocol':'socks','settings':{'servers':[{'address':bind,'port':port}]}},indent=2));return 0
    if args.command=='uninstall':uninstall();return 0
    if args.command=='logs':
        return subprocess.call(['journalctl','-u',monitor_unit(),'-u',CONTAINER+'.service','-n',args.value or '50','--no-pager'])
    if args.command=='speed':speed_probe(args.probe_mb or 4);return 0
    if args.command in ('start','stop','restart'):
        if args.command!='start':run(['systemctl','stop',monitor_unit()])
        tunnel_action(args.command)
        if args.command!='stop':run(['systemctl','start',monitor_unit()])
        return 0
    if args.command=='check':
        _,_,_,speed,reason=evaluate_exit(region,args.gemini_check,args.probe_mb,args.strict_region)
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
                                  observed=(ip,geo,verdict,speed,reason))
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
python3 - "$DATA/settings.json" "$REGION" "$SOCKS_PORT" "$GEMINI_CHECK" "$PROBE_MB" "$STRICT_REGION" "$FAIL_THRESHOLD" "$BACKEND" "$REGION_POOL" "$DENY_REGIONS" "$MIN_SPEED" "$SLOW_THRESHOLD" "$IMPERSONATE" "$TUNNEL_POOL" "$INSTANCE" "$INTERVAL" "$WAIT" "$DELAY" "$BIND" "$PUBLISH_HTTP" "$CONNECTION" "$MENU_MODE" <<'SETTINGS'
import json,sys
obj={'region':sys.argv[2],'port':int(sys.argv[3]),
     'gemini_check':bool(int(sys.argv[4])),'probe_mb':int(sys.argv[5]),
     'strict_region':bool(int(sys.argv[6])),'fail_threshold':int(sys.argv[7]),
     'backend':sys.argv[8], 'region_pool':sys.argv[9].split(),
     'deny_regions':sys.argv[10].split(),'min_speed_kib':float(sys.argv[11]),
     'slow_threshold':int(sys.argv[12]),'impersonate':bool(int(sys.argv[13])),
     'tunnel_pool':int(sys.argv[14]),'instance':int(sys.argv[15]),
     'interval':int(sys.argv[16]),'wait':int(sys.argv[17]),'delay':int(sys.argv[18]),'bind':sys.argv[19],'publish_http':bool(int(sys.argv[20])),'connection_type':sys.argv[21],'menu_mode':sys.argv[22]}
with open(sys.argv[1],'w') as f:json.dump(obj,f,indent=2);f.write('\n')
SETTINGS
chmod 600 "$DATA/settings.json"
write_menu_module > "$APP/autopin_menu.py"
chmod 700 "$APP/autopin_menu.py"
installer_tmp=$(mktemp "$APP/installer.XXXXXX")
{
    printf '#!/usr/bin/env bash\n# Forcus Auto-Pin offline installer v4.1.2\n'
    declare -f autopin_install_main
    printf '\nautopin_install_main "$@"\n'
} > "$installer_tmp"
chmod 700 "$installer_tmp"
mv -f "$installer_tmp" "$APP/install_psiphon_autopin.sh"
cat > /usr/local/sbin/auto-pin <<'MENU_LAUNCHER'
#!/usr/bin/env bash
# Managed by Forcus Auto-Pin menu
set -euo pipefail
for menu_module in /opt/psiphon-autopin/autopin_menu.py /opt/psiphon-autopin-[0-9]*/autopin_menu.py; do
    if [[ -f $menu_module ]]; then exec python3 "$menu_module" "$@"; fi
done
echo 'Auto-Pin menu is not installed. Run install_psiphon_autopin.sh first.' >&2
exit 1
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
Description=Forcus Psiphon Auto-Pin v4.1.2 server rotation and Google geo monitor
Wants=network-online.target $TUNNEL_DEP
After=network-online.target docker.service $TUNNEL_DEP
Requires=docker.service
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStart=/usr/bin/python3 $APP/psiphon_autopin.py monitor --instance $INSTANCE --interval $INTERVAL --wait $WAIT --delay $DELAY $EXTRA_FLAGS
Restart=always
RestartSec=30
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
for alias in "psiphon-autopin$SUFFIX" "$CONTAINER"; do
    cat > "/usr/local/sbin/$alias" <<EOF
#!/usr/bin/env bash
if (( \$# == 0 )); then set -- status; fi
exec /usr/bin/python3 "$APP/psiphon_autopin.py" "\$@" --instance $INSTANCE
EOF
    chmod 755 "/usr/local/sbin/$alias"
done
# Confirm that both proxy sockets are bound only to loopback before enabling monitoring.
# A slow Psiphon tunnel need not be ready yet; listener visibility is checked for up to 20s.
for _ in $(seq 1 20); do
    verify_proxy_binding
    if proxy_listeners_ready; then
        echo '[OK] Both proxies are published only on loopback.'
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
printf '\n[OK] Forcus Psiphon Auto-Pin v4.1.2 installed\n'
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
}
autopin_install_main "$@"
