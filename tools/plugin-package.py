#!/usr/bin/env python3
"""SplitSwan package v1. No third-party dependencies, plugin code is never executed."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import struct
import sys
import unicodedata
import zipfile

MIB = 1024 * 1024
ARCHIVE_LIMIT, EXPANDED_LIMIT, FILE_LIMIT = 20*MIB, 100*MIB, 20*MIB
MANIFEST_LIMIT, ENTRY_LIMIT = 65536, 1000
RUNTIMES = ['sh', 'bash', 'zsh', 'python3', 'node']
FIELDS = {'formatVersion','id','name','author','description','version','minimumAppVersion','entrypoint','interval','runtime','dependencies','settings','files'}
VERSION = re.compile(r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$')

class Invalid(ValueError): pass

def require(condition, reason):
    if not condition: raise Invalid(reason)

def digest(data): return hashlib.sha256(data).hexdigest()
def key(path): return unicodedata.normalize('NFC', path).lower()
def valid_version(value):
    if not isinstance(value, str) or not VERSION.fullmatch(value): return False
    main = value.split('+')[0]
    core, _, pre = main.partition('-')
    return all(int(x) <= 9223372036854775807 for x in core.split('.')) and all(not (x.isascii() and x.isdecimal() and (len(x)>1 and x[0]=='0' or int(x)>9223372036854775807)) for x in pre.split('.'))

def path_ok(path):
    return isinstance(path,str) and 0 < len(path.encode()) <= 512 and not any(c in path for c in '\\:') and not any(unicodedata.category(c) in ('Cc','Cf','Zl','Zp') and ord(c)!=0x200d and not 0xe0020<=ord(c)<=0xe007f for c in path) and not any(ord(c)<32 or ord(c)==127 or 0x202a<=ord(c)<=0x202e or 0x2066<=ord(c)<=0x2069 for c in path) and all(p and p not in ('.','..') and not p.endswith((' ','.')) for p in path.split('/'))

def sensitive(path):
    return any(p in {'.git','.env','company.env','credentials.json','token.json','tokens.json','client_secret.json','id_rsa','id_ed25519','plugin-state','node_modules','__pycache__'} or p.startswith('.env.') or p.endswith(('.pem','.key','.p12','.log')) for p in path.lower().split('/'))

def manifest(data):
    require(len(data)<=MANIFEST_LIMIT, 'Manifest 超過 64 KiB')
    m=json.loads(data)
    require(isinstance(m,dict) and FIELDS<=set(m)<=FIELDS|{'legacyReplacement'}, 'Manifest 欄位不完整或含不支援欄位')
    require(type(m['formatVersion']) is int and m['formatVersion']==1, '不支援格式版本')
    require(isinstance(m['id'],str) and len(m['id'])<=120 and re.fullmatch(r'[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+',m['id']), '識別碼須為小寫反向網域格式')
    require(valid_version(m['version']) and valid_version(m['minimumAppVersion']), '版本須遵守 SemVer')
    if 'legacyReplacement' in m:
        r=m['legacyReplacement']
        require(isinstance(r,dict) and set(r)=={'fileName','sha256s'}, '舊腳本取代宣告不合法')
        n=r['fileName'];h=r['sha256s']
        require(path_ok(n) and '/' not in n and not n.startswith('.') and not sensitive(n), '舊腳本檔名不合法')
        require(isinstance(h,list) and 1<=len(h)<=20 and all(isinstance(v,str) and re.fullmatch('[a-f0-9]{64}',v) for v in h) and len(set(h))==len(h), '舊腳本 SHA-256 清單不合法')
    for field in ('name','author','description'):
        s=m[field]
        require(isinstance(s,str) and s.strip() and len(s)<=500 and not any(unicodedata.category(c) in ('Cc','Cf','Zl','Zp') and ord(c)!=0x200d and not 0xe0020<=ord(c)<=0xe007f for c in s), '說明文字不合法')
    require(type(m['interval']) is int and 30<=m['interval']<=86400, '間隔須為 30–86400 秒')
    require(type(m['settings']) is bool and m['runtime'] in RUNTIMES, 'runtime 或 settings 不合法')
    deps=m['dependencies']
    require(isinstance(deps,list) and len(deps)<=5 and all(isinstance(d,str) and d in RUNTIMES for d in deps) and len(set(deps))==len(deps), '依賴不合法')
    files=m['files']
    require(isinstance(files,list) and 0<len(files)<ENTRY_LIMIT, '檔案數量不合法')
    seen={'manifest.json'}
    for f in files:
        require(isinstance(f,dict) and set(f)=={'path','sha256','executable'}, '檔案描述不合法')
        require(path_ok(f['path']) and not sensitive(f['path']) and key(f['path']) not in seen, '路徑不安全、敏感或重複')
        require(isinstance(f['sha256'],str) and re.fullmatch('[a-f0-9]{64}',f['sha256']) and type(f['executable']) is bool, '雜湊或 executable 不合法')
        seen.add(key(f['path']))
    require(any(f['path']==m['entrypoint'] and f['executable'] for f in files), '入口未宣告為可執行')
    require(not any(key(b['path']).startswith(key(a['path'])+'/') for a in files for b in files if a!=b), '檔案與資料夾衝突')
    return m

def check_contents(m, contents):
    require(set(contents)=={'manifest.json'}|{f['path'] for f in m['files']}, '檔案清單不完整或含未宣告檔案')
    require(sum(map(len,contents.values()))<=EXPANDED_LIMIT, '解壓後超過 100 MiB')
    for f in m['files']:
        data=contents[f['path']]
        require(len(data)<=FILE_LIMIT and digest(data)==f['sha256'], '檔案雜湊不符或過大：'+f['path'])
    entry=contents[m['entrypoint']].split(b'\n',1)[0]
    require(entry in [('#!/usr/bin/env '+m['runtime']).encode(),('#!/bin/'+m['runtime']).encode(),('#!/usr/bin/'+m['runtime']).encode()], '入口 shebang 與 runtime 不一致')

def read_bounded(path, limit):
    require(path.is_file() and not path.is_symlink() and path.stat().st_size<=limit, '檔案不是一般檔案或過大：'+str(path))
    with path.open('rb') as f: data=f.read(limit+1)
    require(len(data)<=limit,'檔案過大')
    return data

def from_directory(root, rehash=False):
    root=root.resolve()
    data=read_bounded(root/'manifest.json',MANIFEST_LIMIT)
    m=manifest(data)
    contents={}
    for f in m['files']:
        p=root/f['path']
        require(not any(x.is_symlink() for x in [p,*p.parents] if x!=root and root in x.parents), '來源包含連結')
        require(root in p.resolve().parents,'來源離開套件根目錄')
        contents[f['path']]=read_bounded(p,FILE_LIMIT)
        if rehash: f['sha256']=digest(contents[f['path']])
    if rehash: data=(json.dumps(m,ensure_ascii=False,indent=2)+'\n').encode()
    contents['manifest.json']=data
    # 開發資料夾可以有其他未列入檔案；它們永遠不會被打包。
    check_contents(m,contents)
    return m,contents

def zip_preflight(data):
    require(22<=len(data)<=ARCHIVE_LIMIT,'ZIP 大小不合法')
    e=None
    for i in range(len(data)-22,max(-1,len(data)-65558),-1):
        if data[i:i+4]==b'PK\x05\x06' and i+22+struct.unpack_from('<H',data,i+20)[0]==len(data): e=i;break
    require(e is not None,'ZIP 缺少結尾')
    _,disk,cd_disk,entries_disk,count,size,start,_=struct.unpack_from('<I4H2IH',data,e)
    require(disk==cd_disk==0 and entries_disk==count and 1<=count<=ENTRY_LIMIT and start+size==e,'分卷、ZIP64 或不完整 ZIP')
    p=start; result={}; seen=set();nodes={};total=0
    for _ in range(count):
        require(p+46<=e and data[p:p+4]==b'PK\x01\x02','中央目錄損壞')
        fields=struct.unpack_from('<I6H3I5H2I',data,p)
        _,_,_,flags,method,_,_,_,compressed,expanded,length,extra,comment,disk,_,attributes,offset=fields
        require(fields[2]<=20 and flags&0x2041==0 and method in (0,8) and disk==0 and p+46+length+extra+comment<=e and expanded<=FILE_LIMIT and compressed<=ARCHIVE_LIMIT,'不支援 ZIP 項目')
        kind=(attributes>>16)&0xf000
        require(kind in (0,stat.S_IFREG,stat.S_IFDIR),'拒絕連結與特殊檔案')
        extra_offset=p+46+length;extra_end=extra_offset+extra
        while extra_offset<extra_end:
            require(extra_offset+4<=extra_end,'延伸欄位損壞')
            field_id,field_size=struct.unpack_from('<HH',data,extra_offset)
            require(field_id!=1,'不支援 ZIP64');extra_offset+=4+field_size
            require(extra_offset<=extra_end,'延伸欄位損壞')
        raw=data[p+46:p+46+length];name=raw.decode('utf-8');isdir=name.endswith('/');path=name[:-1] if isdir else name
        require(path_ok(path) and not sensitive(path) and key(path) not in seen and not (kind==stat.S_IFDIR and not isdir) and not (kind==stat.S_IFREG and isdir) and (not isdir or expanded==0),'路徑不安全或重複')
        seen.add(key(path))
        components=path.split('/')
        for i in range(len(components)):
            node=key('/'.join(components[:i+1]));directory=i<len(components)-1 or isdir
            require(node not in nodes or nodes[node]==directory,'檔案與資料夾路徑衝突')
            nodes[node]=directory
            require(len(nodes)<=ENTRY_LIMIT,'含隱含資料夾的項目超過 1,000')
        require(offset+30<=start and data[offset:offset+4]==b'PK\x03\x04','本機檔頭損壞')
        local=struct.unpack_from('<I5H3I2H',data,offset)
        require(local[1]<=20 and local[2]==flags and local[3]==method and local[-2]==length,'本機檔頭不一致')
        body=offset+30+length+local[-1]
        require(body+compressed<=start and data[offset+30:offset+30+length]==raw,'本機檔頭不完整')
        total+=expanded;require(total<=EXPANDED_LIMIT,'解壓後超過上限')
        result[name]=expanded;p+=46+length+extra+comment
    require(p==e,'中央目錄項目不完整')
    return result

def from_archive(path):
    data=read_bounded(path,ARCHIVE_LIMIT)
    expected=zip_preflight(data)
    contents={}
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        require(len(z.infolist())==len(expected),'列舉不完整')
        for f in z.infolist():
            if f.is_dir(): continue
            limit=MANIFEST_LIMIT if f.filename=='manifest.json' else FILE_LIMIT
            require(f.filename in expected and f.file_size<=limit,'檔案過大或不一致')
            with z.open(f) as stream: data=stream.read(min(limit,expected[f.filename])+1)
            require(len(data)==expected[f.filename],'大小不一致')
            contents[f.filename]=data
        require('manifest.json' in contents,'缺少根目錄 manifest.json')
        m=manifest(contents['manifest.json'])
        for name in expected:
            require(not name.endswith('/') or any(f['path'].startswith(name) for f in m['files']),'未宣告資料夾')
    check_contents(m,contents)
    return m,contents

def pack(root, output):
    m,contents=from_directory(root,rehash=True)
    require(output.resolve()!=root.resolve()/'manifest.json' and not output.exists(),'輸出已存在，請使用新檔名')
    output.parent.mkdir(parents=True,exist_ok=True)
    modes={f['path']:0o700 if f['executable'] else 0o600 for f in m['files']}
    try:
        with zipfile.ZipFile(output,'x',zipfile.ZIP_DEFLATED) as z:
            for name in sorted(contents):
                info=zipfile.ZipInfo(name,(2020,1,1,0,0,0));info.create_system=3
                info.external_attr=(stat.S_IFREG|modes.get(name,0o600))<<16
                info.compress_type=zipfile.ZIP_DEFLATED
                z.writestr(info,contents[name])
        from_archive(output)
    except Exception:
        output.unlink(missing_ok=True);raise
    return m

def init(root, package_id):
    require(not root.exists(),'目錄已存在')
    require(re.fullmatch(r'[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+',package_id or '') and len(package_id)<=120,'請提供小寫反向網域識別碼')
    root.mkdir(parents=True)
    files={'main.sh':b'#!/bin/sh\nprintf "Sharing Demo\\n---\\nHello from a package\\n"\n','README.md':'# 分享外掛範例\n不讀取私人資料。狀態請寫入 SPLITSWAN_PLUGIN_STATE。\n'.encode()}
    m=dict(formatVersion=1,id=package_id,name='分享外掛範例',author='Example Developer',description='可匯入、更新及匯出的去識別化範例。',version='1.0.0',minimumAppVersion='1.8.5',entrypoint='main.sh',interval=300,runtime='sh',dependencies=[],settings=False,files=[dict(path=p,sha256=digest(d),executable=p=='main.sh') for p,d in files.items()])
    for p,data in files.items(): (root/p).write_bytes(data)
    (root/'manifest.json').write_text(json.dumps(m,ensure_ascii=False,indent=2)+'\n')
    return m

def main():
    parser=argparse.ArgumentParser(description='SplitSwan 外掛安裝包工具（不執行外掛）')
    sub=parser.add_subparsers(dest='command',required=True)
    p=sub.add_parser('init');p.add_argument('path',type=Path);p.add_argument('--id',required=True)
    for command in ('validate','inspect'):
        p=sub.add_parser(command);p.add_argument('path',type=Path)
    p=sub.add_parser('pack');p.add_argument('path',type=Path);p.add_argument('-o','--output',type=Path,required=True)
    args=parser.parse_args()
    try:
        if args.command=='init': m=init(args.path,args.id)
        elif args.command=='pack': m=pack(args.path,args.output)
        else: m,_=from_directory(args.path) if args.path.is_dir() else from_archive(args.path)
        print(json.dumps({'valid':True,'manifest':m},ensure_ascii=False,indent=2))
    except (ValueError,OSError,KeyError,TypeError,zipfile.BadZipFile,RuntimeError,struct.error) as error:
        print('驗證失敗：'+str(error),file=sys.stderr);return 1
    return 0
if __name__=='__main__': sys.exit(main())
