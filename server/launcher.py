"""Local gateway launcher; optional credentials in the macOS login Keychain."""
import getpass, json, os, runpy, subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parent

def keychain(account, operation='read', key=None):
    payload = {'account': account, 'operation': operation}
    if key is not None: payload['key'] = key
    try:
        helper_env = dict(os.environ)
        if Path('/Applications/Xcode.app/Contents/Developer').exists():
            helper_env['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
        result = subprocess.run(['/usr/bin/swift', str(ROOT / 'keychain.swift')], env=helper_env,
            input=json.dumps(payload), text=True, capture_output=True, timeout=60)
        if result.returncode == 0: return result.stdout.strip()
        if result.returncode != 3: print('钥匙串暂不可用；可继续使用本次输入的密钥。')
    except (OSError, subprocess.TimeoutExpired):
        print('钥匙串暂不可用；可继续使用本次输入的密钥。')
    return None

def enter_key(account):
    label = 'OpenAI' if account == 'openai' else '高德 Web 服务'
    value = getpass.getpass(f'粘贴 {label} Key（隐藏输入，留空取消）：').strip()
    if value and input('保存到本机钥匙串，以后免输入？[y/N]：').strip().lower() == 'y':
        if keychain(account, 'save', value) is not None: print('已保存到钥匙串。')
    return value

def main():
    if '--configure' in sys.argv:
        account = 'amap' if input('配置 1 OpenAI / 2 高德 [1]：').strip() == '2' else 'openai'
        if input('操作 1 保存或更换 / 2 删除 [1]：').strip() == '2':
            if keychain(account, 'delete') is not None: print('已删除保存的密钥；运行中的服务需重启。')
        else:
            enter_key(account)
            print('配置结束；运行中的服务需重启后生效。')
        return
    os.environ.setdefault('MODEL_BASE_URL', 'https://api.openai.com/v1')
    os.environ.setdefault('MODEL_NAME', 'gpt-5')
    print('鲸伴 · 模型与出行服务')
    key = os.environ.get('MODEL_API_KEY') or keychain('openai') or enter_key('openai')
    if not key: raise SystemExit('未配置模型密钥，已退出。')
    os.environ['MODEL_API_KEY'] = key
    map_key = os.environ.get('AMAP_API_KEY') or keychain('amap')
    if map_key: os.environ['AMAP_API_KEY'] = map_key
    print('高德：' + ('已配置（权限待实际查询验证）' if map_key else '未配置，日程功能可正常使用。双击 configure.command 配置。'))
    try:
        address = subprocess.check_output(['/usr/sbin/ipconfig', 'getifaddr', 'en0'], text=True, stderr=subprocess.DEVNULL).strip()
        print('手机服务地址：http://' + address + ':8765')
        print('换 Wi-Fi 后地址可能改变，请同步修改手机设置。')
    except (OSError, subprocess.CalledProcessError):
        print('请在 Mac 网络设置中确认当前局域网 IP。')
    print('手机与 Mac 请连接同一可信 Wi-Fi。保持此窗口打开；Ctrl+C 停止。')
    runpy.run_path(str(ROOT / 'server.py'), run_name='__main__')

if __name__ == '__main__': main()
