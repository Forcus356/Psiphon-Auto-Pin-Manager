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
