#!/usr/bin/env python3
"""同一批 ZIP 同時交給 Python 工具與原生 App 驗證。所有檔案都在測試暫存目錄。"""
import copy
import importlib.util
import json
from pathlib import Path
import stat
import struct
import sys
import warnings
import zipfile

sys.dont_write_bytecode=True
spec=importlib.util.spec_from_file_location('package_tool',Path(__file__).resolve().parents[1]/'tools/plugin-package.py')
p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)
root=Path(sys.argv[1]);root.mkdir(parents=True,exist_ok=True)
source=root/'source';base=p.init(source,'org.example.fixture')
# 會記錄呼叫與狀態路徑，用於觀察「匯入零執行」與更新後的狀態連續性。
script=b'''#!/bin/sh
printf 'start\\n' >> "$SPLITSWAN_PLUGIN_STATE/calls"
if [ -f "$SPLITSWAN_PLUGIN_STATE/hold" ]; then
  touch "$SPLITSWAN_PLUGIN_STATE/started"
  while [ -f "$SPLITSWAN_PLUGIN_STATE/hold" ]; do /bin/sleep 0.02; done
fi
printf 'Package Fixture\\n---\\nversion=%s\\n' "$SPLITSWAN_PLUGIN_VERSION"
printf '%s' "$SPLITSWAN_PLUGIN_ROOT" > "$SPLITSWAN_PLUGIN_STATE/root"
printf '%s' "$SPLITSWAN_PLUGIN_ID" > "$SPLITSWAN_PLUGIN_STATE/id"
/bin/cat "$SPLITSWAN_PLUGIN_ROOT/resources/defaults.json" > "$SPLITSWAN_PLUGIN_STATE/resource"
'''
(source/'main.sh').write_bytes(script)
base['files'][0]['sha256']=p.digest(script)
base['files'].append(dict(path='resources/defaults.json',sha256=p.digest(b'{"example":true}\n'),executable=False))
contents={'main.sh':script,'README.md':(source/'README.md').read_bytes(),'resources/defaults.json':b'{"example":true}\n'}
cases=[]
def archive(name,m=None,extra=(),remove=(),mutate=None,valid=False,compression=zipfile.ZIP_DEFLATED):
    path=root/(name+'.splitswan-plugin');m=copy.deepcopy(m or base)
    entries=[('manifest.json',(json.dumps(m,ensure_ascii=False,indent=2)+'\n').encode(),stat.S_IFREG|0o600)]
    entries += [(k,v,stat.S_IFREG|0o600) for k,v in contents.items() if k not in remove]
    entries += list(extra)
    with warnings.catch_warnings():
        warnings.simplefilter('ignore')
        with zipfile.ZipFile(path,'w',compression) as z:
            for key,data,mode in entries:
                info=zipfile.ZipInfo(key);info.create_system=3;info.external_attr=mode<<16;info.compress_type=compression
                z.writestr(info,data)
    if mutate: path.write_bytes(mutate(bytearray(path.read_bytes())))
    cases.append(dict(file=path.name,valid=valid))
    return path
archive('valid',valid=True)
# UTF-8 路徑即使未設 ZIP 語言旗標，也必須與預檢及 Manifest 使用相同解碼。
unicode_manifest=copy.deepcopy(base)
unicode_path='resources/說明.txt'
unicode_manifest['files'].append(dict(path=unicode_path,sha256=p.digest(b'example'),executable=False))
archive('utf8-path',unicode_manifest,extra=[(unicode_path,b'example',stat.S_IFREG|0o600)],valid=True)
def clear_utf8_flags(data):
    end=data.rfind(b'PK\x05\x06')
    count=struct.unpack_from('<H',data,end+10)[0]
    pos=struct.unpack_from('<I',data,end+16)[0]
    for _ in range(count):
        flags=struct.unpack_from('<H',data,pos+8)[0] & ~0x800
        local=struct.unpack_from('<I',data,pos+42)[0]
        struct.pack_into('<H',data,pos+8,flags)
        struct.pack_into('<H',data,local+6,flags)
        lengths=struct.unpack_from('<HHH',data,pos+28)
        pos+=46+sum(lengths)
    return data
archive('utf8-path-unflagged',unicode_manifest,extra=[(unicode_path,b'example',stat.S_IFREG|0o600)],mutate=clear_utf8_flags,valid=True)
# Python zipfile 按 ZIP 旗標選 CP437，因此不接受這個 App 相容性案例。
cases[-1]['pythonValid']=False

legacyScript=b'''#!/bin/sh
if [ -f "$SPLITSWAN_PLUGIN_STATE/hold" ]; then
  touch "$SPLITSWAN_PLUGIN_STATE/started"
  while [ -f "$SPLITSWAN_PLUGIN_STATE/hold" ]; do /bin/sleep 0.02; done
fi
echo Legacy
''' 
(root/'legacy.1m.sh').write_bytes(legacyScript)
replacement=copy.deepcopy(base);replacement['version']='1.2.0';replacement['minimumAppVersion']='1.8.6'
replacement['legacyReplacement']={'fileName':'legacy.1m.sh','sha256s':[p.digest(legacyScript)]}
archive('legacy-upgrade',replacement,valid=True)
replacementUpdate=copy.deepcopy(replacement);replacementUpdate['version']='1.3.0';archive('legacy-next',replacementUpdate,valid=True)
for label,value in [('null',None),('path',{'fileName':'../legacy.sh','sha256s':[p.digest(legacyScript)]}),('empty',{'fileName':'legacy.sh','sha256s':[]}),('duplicate',{'fileName':'legacy.sh','sha256s':[p.digest(legacyScript)]*2}),('unknown',{'fileName':'legacy.sh','sha256s':[p.digest(legacyScript)],'hook':'run'})]:
    invalid=copy.deepcopy(replacement);invalid['legacyReplacement']=value;archive('legacy-'+label,invalid)

archive('stored',valid=True,compression=zipfile.ZIP_STORED)
archive('with-directory',extra=[('resources/',b'',stat.S_IFDIR|0o700)],valid=True)
new=copy.deepcopy(base);new['version']='1.1.0';new['name']='Updated Fixture';archive('update',new,valid=True)
same=copy.deepcopy(base);same['description']='Same version changed';archive('same-version',same,valid=True)
future=copy.deepcopy(base);future['minimumAppVersion']='999.0.0';archive('future',future,valid=False)
# Python 工具不限制本機 App 版本；原生 App 另行驗證最低版本。
cases[-1]['pythonValid']=True
bad=copy.deepcopy(base);bad['formatVersion']=2;archive('format',bad)
bad=copy.deepcopy(base);bad['hooks']={'install':'run'};archive('unknown-field',bad)
bad=copy.deepcopy(base);bad['files'][0]['extra']=True;archive('unknown-file-field',bad)
bad=copy.deepcopy(base);bad['files'][0]['sha256']='0'*64;archive('hash-mismatch',bad)
bad=copy.deepcopy(base);bad['entrypoint']='other.sh';archive('wrong-entry',bad)
bad=copy.deepcopy(base);bad['runtime']='node';archive('wrong-runtime',bad)
bad=copy.deepcopy(base);bad['interval']=29;archive('interval',bad)
bad=copy.deepcopy(base);bad['version']='1.0.0-01';archive('bad-version',bad)
archive('undeclared',extra=[('extra.txt',b'extra',stat.S_IFREG|0o600)])
archive('missing',remove=['README.md'])
archive('traversal',extra=[('../escape',b'x',stat.S_IFREG|0o600)])
archive('absolute',extra=[('/tmp/escape',b'x',stat.S_IFREG|0o600)])
archive('duplicate',extra=[('main.sh',script,stat.S_IFREG|0o600)])
archive('case-collision',extra=[('MAIN.SH',script,stat.S_IFREG|0o600)])
archive('unicode-collision',extra=[('caf\u00e9.txt',b'x',stat.S_IFREG|0o600),('cafe\u0301.txt',b'x',stat.S_IFREG|0o600)])
archive('symlink',extra=[('link',b'main.sh',stat.S_IFLNK|0o700)])
archive('fifo',extra=[('pipe',b'',stat.S_IFIFO|0o600)])
archive('sensitive',extra=[('.env',b'EXAMPLE=placeholder',stat.S_IFREG|0o600)])
archive('unused-directory',extra=[('unused/',b'',stat.S_IFDIR|0o700)])
archive('many-entries',extra=[('unused/%04d'%i,b'',stat.S_IFREG|0o600) for i in range(1000)])
def central(data,change):
    pos=data.index(b'PK\x01\x02');change(data,pos);return data
def encrypted(d):
    for sig,offset in [(b'PK\x03\x04',6),(b'PK\x01\x02',8)]:
        pos=d.index(sig);struct.pack_into('<H',d,pos+offset,struct.unpack_from('<H',d,pos+offset)[0]|1)
    return d
archive('encrypted',mutate=encrypted)
archive('oversized-entry',mutate=lambda d:central(d,lambda d,o:struct.pack_into('<I',d,o+24,21*p.MIB)))
archive('crc',mutate=lambda d:central(d,lambda d,o:struct.pack_into('<I',d,o+16,0)))
archive('partial-central',mutate=lambda d:central(d,lambda d,o:d.__setitem__(o,0)))
archive('local-mismatch',mutate=lambda d:d.__setitem__(30,ord('X')) or d)
archive('multidisk',mutate=lambda d:struct.pack_into('<H',d,len(d)-18,1) or d)
archive('truncated',mutate=lambda d:d[:-8])
nested=copy.deepcopy(base);extra=[]
for i in range(100):
    path='d%03d/'%i + 'nested/'*12 + 'value.txt'
    nested['files'].append(dict(path=path,sha256=p.digest(b'x'),executable=False))
    extra.append((path,b'x',stat.S_IFREG|0o600))
archive('implicit-directory-limit',nested,extra=extra)
archive('manifest-directory-conflict',extra=[('manifest.json/child',b'x',stat.S_IFREG|0o600)])
oversized=root/'archive-limit.splitswan-plugin'
with oversized.open('wb') as stream: stream.truncate(p.ARCHIVE_LIMIT+1)
cases.append(dict(file=oversized.name,valid=False))
bad=copy.deepcopy(base);bad['description']='X'*65537;archive('manifest-limit',bad)
def remove_manifest(data):
    # 以相同長度改名，保持 ZIP 結構與 CRC 完整。
    return data.replace(b'manifest.json',b'manifest.jsox')
archive('no-root-manifest',mutate=remove_manifest)

archive('zip64-header',mutate=lambda d:central(d,lambda d,o:struct.pack_into('<H',d,o+6,45)))
# 將允許清單以外的開發檔案留在來源，pack 必須排除它，不得猜測依賴。
(source/'manifest.json').write_text(json.dumps(base))
(source/'resources').mkdir();(source/'resources/defaults.json').write_bytes(contents['resources/defaults.json'])
(source/'.env').write_text('EXAMPLE=not-exported')
packed=root/'cli-packed.splitswan-plugin';p.pack(source,packed)
cases.append(dict(file=packed.name,valid=True))
with zipfile.ZipFile(packed) as z: assert '.env' not in z.namelist()
failed=0
for case in cases:
    try: p.from_archive(root/case['file']);ok=True
    except Exception: ok=False
    if ok!=case.get('pythonValid',case['valid']): print('❌ Python 共用案例：'+case['file']);failed+=1
(root/'cases.json').write_text(json.dumps(cases))
print('Python 共用安裝包案例：'+str(len(cases))+'，失敗 '+str(failed))
sys.exit(1 if failed else 0)
