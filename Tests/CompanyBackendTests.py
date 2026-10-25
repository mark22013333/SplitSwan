#!/usr/bin/env python3
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]
passed = failed = 0

def check(name, value):
    global passed, failed
    print(('✅ ' if value else '❌ ') + name, flush=True)
    if value:
        passed += 1
    else:
        failed += 1

def executable(path, text):
    path.write_text(text)
    path.chmod(0o755)

with tempfile.TemporaryDirectory(prefix='splitswan-company-') as temporary:
    root = Path(temporary)
    state = root / 'state'
    state.mkdir(mode=0o700)
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    commands = root / 'commands'
    charon_env = root / 'charon-env'
    executable(bin_dir / 'pgrep', '#!/bin/sh\nexit 1\n')
    executable(bin_dir / 'swanctl', f'''#!/bin/sh
printf '%s\\n' "$*" >> '{commands}'
case "$*" in *--initiate*) exit 0 ;; esac
exit 0
''')
    executable(bin_dir / 'charon', f'''#!/bin/sh
printf '%s\\n' "${{STRONGSWAN_CONF:-normal}}" >> '{charon_env}'
''')
    worker_text = (REPO / 'tools/external-vpn/company-backend').read_text()
    worker_text = '\n'.join(line for line in worker_text.splitlines() if 'root worker required' not in line)
    worker_text = worker_text.replace('PATH=/usr/bin:/bin:/usr/sbin:/sbin', f'PATH={bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin')
    worker_text = worker_text.replace('SWANCTL="$SS/bin/swanctl"', f'SWANCTL={bin_dir}/swanctl')
    worker_text = worker_text.replace('CHARON="$SS/libexec/ipsec/charon"', f'CHARON={bin_dir}/charon')
    worker_text = worker_text.replace('/var/run/splitswan-external/', str(state) + '/')
    worker = root / 'worker'
    executable(worker, worker_text)
    def run_worker(*args):
        return subprocess.run(['/bin/bash', str(worker), *args], capture_output=True, text=True, timeout=15)
    result = run_worker('dual-mode')
    deadline = time.monotonic() + 3
    while not charon_env.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    calls = commands.read_text()
    check('dual mode 只載入隔離 connections 與 credentials', result.returncode == 0 and '--load-conns --file ' + str(state / 'swanctl-dual.conf') in calls and '--load-creds --noprompt' in calls and '--load-all' not in calls)
    check('daemon 啟動只使用固定隔離設定', charon_env.read_text().strip() == str(state / 'strongswan-dual.conf'))
    check('dual up 只 initiate 指定公司', run_worker('dual-up', '2').returncode == 0 and '--initiate --child corp --ike vpn2 --timeout 20' in commands.read_text())
    check('dual down 只 terminate 指定公司', run_worker('dual-down', '2').returncode == 0 and '--terminate --ike vpn2 --force --timeout 5' in commands.read_text())
    check('非法 dual slot 拒絕', run_worker('dual-up', '4').returncode != 0)
    calls_before_normal = commands.read_text()
    normal = run_worker('normal-mode')
    normal_calls = commands.read_text()[len(calls_before_normal):]
    check('normal mode 只載入 credentials，不預載自動啟動連線', normal.returncode == 0 and '--load-creds --noprompt' in normal_calls and '--load-all' not in normal_calls and '--load-conns' not in normal_calls)
    check('normal mode 恢復正常 daemon 設定', charon_env.read_text().splitlines()[-1] == 'normal')

    coordinator_worker = root / 'coordinator-worker'
    coordinator_calls = root / 'coordinator-calls'
    executable(coordinator_worker, f'''#!/bin/sh
printf '%s\\n' "$*" >> '{coordinator_calls}'
printf 'ok %s\\n' "$1"
''')
    system = (REPO / 'tools/external-vpn/ExternalVPNSystem.swift').read_text()
    system = system.replace('"/var/run/splitswan-external"', json.dumps(str(state)))
    system = system.replace('geteuid() == 0', 'geteuid() == getuid()').replace('info.st_uid == 0', 'info.st_uid == getuid()')
    (root / 'ExternalVPNSystem.swift').write_text(system)
    company = (REPO / 'tools/external-vpn/CompanyVPNSystem.swift').read_text()
    company = company.replace('"/usr/local/libexec/splitswan-company-backend"', json.dumps(str(coordinator_worker)))
    (root / 'CompanyVPNSystem.swift').write_text(company)
    shutil.copyfile(REPO / 'tools/external-vpn/main.swift', root / 'main.swift')
    binary = root / 'coordinator'
    compile_result = subprocess.run(['swiftc', '-module-cache-path', str(REPO / 'build/test-module-cache'), '-o', str(binary), str(REPO / 'Sources/ExternalVPNLogic.swift'), str(REPO / 'Sources/VPNCoexistenceLogic.swift'), str(root / 'ExternalVPNSystem.swift'), str(root / 'CompanyVPNSystem.swift'), str(REPO / 'tools/external-vpn/RootOperationLifetime.swift'), str(root / 'main.swift'), '-framework', 'SystemConfiguration'], capture_output=True, text=True, timeout=180)
    check('真實 coordinator 來源可編譯成隔離 fixture', compile_result.returncode == 0)
    if compile_result.returncode:
        print(compile_result.stderr)
        raise SystemExit(1)
    route_fixture = root / 'route-arguments'
    route_fixture.mkdir()
    (route_fixture / 'main.swift').write_text('''import Foundation
let network = try ExternalIPv4Network("192.0.2.0/24")
let direct = ExternalRoute(network: network, gateway: "link#4", interface: "en0", flags: "US1", nextHopKind: .directInterface)
let gateway = ExternalRoute(network: network, gateway: "192.0.2.1", interface: "en0", flags: "UGS1")
let rows = [ExternalVPNSystem.routeArguments(direct, operation: "add"), ExternalVPNSystem.routeArguments(direct, operation: "delete"), ExternalVPNSystem.routeArguments(gateway, operation: "add")]
print(String(decoding: try JSONEncoder().encode(rows), as: UTF8.self))
''')
    route_compile = subprocess.run(['swiftc', '-module-cache-path', str(REPO / 'build/test-module-cache'), '-o', str(route_fixture / 'probe'), str(REPO / 'Sources/ExternalVPNLogic.swift'), str(REPO / 'Sources/VPNCoexistenceLogic.swift'), str(root / 'ExternalVPNSystem.swift'), str(root / 'CompanyVPNSystem.swift'), str(REPO / 'tools/external-vpn/RootOperationLifetime.swift'), str(route_fixture / 'main.swift'), '-framework', 'SystemConfiguration'], capture_output=True, text=True, timeout=180)
    check('Darwin route 參數 fixture 可編譯', route_compile.returncode == 0)
    if route_compile.returncode:
        print(route_compile.stderr)
        raise SystemExit(1)
    route_result = subprocess.run([str(route_fixture / 'probe')], capture_output=True, text=True, timeout=10)
    route_rows = json.loads(route_result.stdout)
    check('LAN add 使用真正 interface route 與 proto1', route_rows[0] == ['-n', 'add', '-net', '192.0.2.0/24', '-interface', 'en0', '-proto1'])
    check('LAN delete 使用相同 interface route 型態', route_rows[1] == ['-n', 'delete', '-net', '192.0.2.0/24', '-interface', 'en0'])
    check('gateway route 保留既有 ifp 命令', route_rows[2] == ['-n', 'add', '-net', '192.0.2.0/24', '192.0.2.1', '-ifp', 'en0', '-proto1'])
    environment = dict(os.environ, SUDO_UID=str(os.getuid()))
    def run(*args):
        return subprocess.run([str(binary), *args], env=environment, capture_output=True, text=True, timeout=10)
    check('無 external session 時保留 standalone up', run('company-up', '1').stdout == 'ok up\n')
    check('standalone reload 仍由 coordinator 執行', run('company-reload').stdout == 'ok reload\n')
    check('root CLI 拒絕額外參數', run('company-down', 'extra').returncode != 0)
    check('root CLI 拒絕無效 slot', run('company-up', '4').returncode != 0)
    def network(cidr):
        n = ipaddress.IPv4Network(cidr)
        return {'address': {'value': int(n.network_address)}, 'prefix': n.prefixlen}
    owned = {'network': network('203.0.113.0/24'), 'gateway': '192.0.2.1', 'interface': 'en0', 'flags': 'UGS1'}
    snapshot = {'bootID': 'fixture-boot', 'interface': 'en0', 'address': '192.0.2.9', 'gateway': '192.0.2.1', 'localNetwork': network('192.0.2.0/24'), 'routes': [owned], 'dns': [], 'ipv6TunnelDefault': False, 'defaultDNSServers': [], 'defaultDNSDomains': []}
    record = {'owner': os.getuid(), 'baseline': snapshot, 'profile': {'protectedNetworks': [], 'dnsDomains': [], 'dnsMode': 'preserveVPN'}, 'phase': 'active', 'tunnel': 'utun5', 'addedRoutes': [owned], 'dnsChanges': [], 'message': 'fixture active'}
    journal = state / 'session.json'
    def save(value):
        journal.write_text(json.dumps(value))
        journal.chmod(0o600)
    save(record)
    before = journal.read_bytes()
    check('v1 active 無證據不提供公司能力', json.loads(run('status').stdout).get('companyCapability') is None)
    with (state / 'lock').open('r+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        busy = run('tick')
        value = json.loads(busy.stdout)
        check('root lock busy 對舊 App 保持 active 與路由數', busy.returncode == 0 and value['phase'] == 'active' and value['routeCount'] == 1 and value['busy'])
        refusal = run('company-up', '1')
        check('公司入口同一把鎖且 typed admission busy', refusal.returncode != 0 and refusal.stdout.startswith('admission busy '))
        check('busy 不改 journal bytes', journal.read_bytes() == before)
    before_calls = coordinator_calls.read_text()
    for action in ['company-reload', 'company-reload-settings']:
        check(action + ' 在 active F5 明確拒絕', run(action).stdout.startswith('admission unsupported '))
    check('受保護操作未呼叫 worker', coordinator_calls.read_text() == before_calls)
    check('錯誤操作不改 active journal', journal.read_bytes() == before)
    for phase in ['failed', 'waiting']:
        save(dict(record, phase=phase, addedRoutes=[]))
        blocked_before = journal.read_bytes()
        blocked = run('company-up', '1')
        check(phase + ' 不得降為 standalone 公司連線', blocked.returncode != 0 and blocked.stdout.startswith('admission unsupported ') and coordinator_calls.read_text() == before_calls and journal.read_bytes() == blocked_before)
    save(record)
    journal.chmod(0o644)
    check('journal 0644 拒絕', run('status').returncode != 0)
    journal.chmod(0o600)
    link = state / 'second-link'
    os.link(journal, link)
    check('journal hard link 拒絕', run('status').returncode != 0)
    link.unlink()
    journal.unlink()
    target = root / 'foreign'
    target.write_bytes(before)
    target.chmod(0o600)
    journal.symlink_to(target)
    check('journal symlink 拒絕且目標不變', run('status').returncode != 0 and target.read_bytes() == before)
    journal.unlink()
    record['owner'] += 1
    save(record)
    check('其他使用者 journal 拒絕', run('status').returncode != 0)
    check('未授權 worker 本身維持 root guard', 'root worker required' in (REPO / 'tools/external-vpn/company-backend').read_text())
print(f'通過 {passed}，失敗 {failed}')
raise SystemExit(1 if failed else 0)
