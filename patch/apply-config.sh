#!/usr/bin/env bash
# =============================================================================
# apply-config.sh — 把自建服务器地址/Key 写死进 RustDesk 1.4.9 源码，并生成 custom.txt
#
# 用法:
#   bash patch/apply-config.sh <rustdesk-src-root> <config.json>
#
# 做的事情（与 RustDesk 1.4.9 源码逐行核对过）:
#   1. 修改 libs/hbb_common/src/config.rs
#        RENDEZVOUS_SERVERS → ["<host>"]          (第 120 行)
#        RS_PUB_KEY        → "<key>"              (第 121 行)
#        注: hbb_common 是 submodule，必须在其自己的源码内替换(不能只在根仓库)。
#   2. 删除 src/common.rs 里 read_custom_client() 顶部的 ed25519 签名校验块
#        (const KEY + get_rs_pk + sign::verify —— 约第 2186~2193 行)。
#        删完后 custom.txt 就是 base64(JSON)，客户端直接解码使用。
#   3. Android: 修改 MainService.kt，把 FFI.startServer 的第二个参数从 "" 改为
#        读取 assets/custom.txt 的内容(assets 里的任意文件会被打进 APK)。
#   4. 用 tools/gen_custom_txt.py 生成 custom.txt(挂在源码根目录):
#        {"app-name":.., "override-settings":{custom-rendezvous-server, relay-server,
#         key, hide-network-settings:"Y", ...}}
#
# 每步都有 grep 断言，替换没生效会直接 exit 1，方便在 CI 里第一时间发现。
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

SRC_ROOT="${1:?用法: apply-config.sh <rustdesk-src-root> <config.json>}"
CFG="${2:?用法: apply-config.sh <rustdesk-src-root> <config.json>}"
[ -f "$CFG" ] || { echo "config.json 不存在: $CFG" >&2; exit 1; }
cd "$SRC_ROOT"

# config.json 读取:优先 jq(CI 自带),缺 jq 时回退纯 python3(零依赖)
read_cfg() { # read_cfg <json-expr 或 None-default> <python-expr> <py-default>
  if command -v jq >/dev/null 2>&1; then
    jq -r "$1" "$CFG"
  else
    python3 - "$CFG" "$2" "$3" <<'PYEOF'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
expr = sys.argv[2]
dflt = json.loads(sys.argv[3]) if sys.argv[3] != "NOVALUE" else None
try:
    v = eval(expr, {"cfg": cfg, "json": json})
    sys.stdout.write(str(v) if v is not None else str(dflt))
except Exception:
    sys.stdout.write(str(dflt))
PYEOF
  fi
}

APP_NAME="$(read_cfg '.appName // "RustDesk"'          "cfg.get('appName', 'RustDesk')"                          '"RustDesk"')"
HOST="$(    read_cfg '.server.host'                    "cfg['server']['host']"                                     '""')"
RPORT="$(   read_cfg '.server.rendezvousPort // 21116' "cfg.get('server', {}).get('rendezvousPort', 21116)"      '21116')"
LPORT="$(   read_cfg '.server.relayPort // 21117'      "cfg.get('server', {}).get('relayPort', 21117)"           '21117')"
KEY="$(     read_cfg '.server.key'                     "cfg['server']['key']"                                      '""')"
SIGN_MODE="$(read_cfg '.signMode // "delete"'          "cfg.get('signMode', 'delete')"                            '"delete"')"

[ -n "$HOST" ] || { echo "config.json: 缺少 server.host" >&2; exit 1; }
[ -n "$KEY" ]  || { echo "config.json: 缺少 server.key"  >&2; exit 1; }

echo "== 配置 =="
echo "  appName=$APP_NAME"
echo "  host=$HOST  rport=$RPORT  lport=$LPORT"
echo "  signMode=$SIGN_MODE"

# ---------------------------------------------------------------------------
# 1. hbb_common/src/config.rs: 服务器地址 + Key 常量
# ---------------------------------------------------------------------------
HBB_CFG="libs/hbb_common/src/config.rs"
if [ -f "$HBB_CFG" ]; then
  # 服务器列表
  sed -i "s/pub const RENDEZVOUS_SERVERS: &\[&str\] = &\[\"[^\"]*\"\];/pub const RENDEZVOUS_SERVERS: \&[\&str] = \&[\"$HOST\"];/" "$HBB_CFG"
  grep -F "pub const RENDEZVOUS_SERVERS: &[&str] = &[\"$HOST\"];" "$HBB_CFG" >/dev/null || {
    echo "!! RENDEZVOUS_SERVERS 替换失败，当前内容:" >&2
    grep -n "RENDEZVOUS_SERVERS" "$HBB_CFG" >&2; exit 1; }
  # Key
  sed -i "s/pub const RS_PUB_KEY: &str = \"[^\"]*\";/pub const RS_PUB_KEY: \&str = \"$KEY\";/" "$HBB_CFG"
  grep -F "pub const RS_PUB_KEY: &str = \"$KEY\";" "$HBB_CFG" >/dev/null || {
    echo "!! RS_PUB_KEY 替换失败，当前内容:" >&2
    grep -n "RS_PUB_KEY" "$HBB_CFG" >&2; exit 1; }
  echo "== [OK] hbb_common/src/config.rs 已写死服务器/Key"
else
  echo "!! 未找到 $HBB_CFG（submodule 未拉取？）" >&2; exit 1
fi

# ---------------------------------------------------------------------------
# 2. src/common.rs: 删除 custom.txt 的 ed25519 签名校验
# ---------------------------------------------------------------------------
COMMON="src/common.rs"
if [ -f "$COMMON" ]; then
  python3 - "$COMMON" <<'PY'
import sys
p = sys.argv[1]
src = open(p, encoding="utf-8").read()

needle = '''    const KEY: &str = "5Qbwsde3unUcJBtrx9ZkvUmwFNoExHzpryHuPUdqlWM=";
    let Some(pk) = get_rs_pk(KEY) else {
        log::error!("Failed to parse public key of custom client");
        return;
    };
    let Ok(data) = sign::verify(&data, &pk) else {
        log::error!("Failed to dec custom client config");
        return;
    };
'''
replacement = '''    // [custom-build] signMode=delete: ed25519 signature check removed by apply-config.sh
'''
if needle not in src:
    sys.stderr.write("!! 未匹配到 read_custom_client 签名校验块(源码版本与 1.4.9 不一致?)\n")
    sys.exit(1)
open(p, "w", encoding="utf-8").write(src.replace(needle, replacement, 1))
PY
  grep -q "signMode=delete" "$COMMON" || { echo "!! common.rs 签名校验删除失败" >&2; exit 1; }
  echo "== [OK] src/common.rs 已移除 custom.txt 签名校验"
else
  echo "!! 未找到 $COMMON" >&2; exit 1
fi

# ---------------------------------------------------------------------------
# 3. Android: MainService.kt 读取 assets/custom.txt 传给 FFI.startServer
# ---------------------------------------------------------------------------
MSVC="flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/MainService.kt"
if [ -f "$MSVC" ]; then
  python3 - "$MSVC" <<'PY'
import sys
p = sys.argv[1]
src = open(p, encoding="utf-8").read()

old_call = "FFI.startServer(configPath, \"\")"
new_call = "FFI.startServer(configPath, readCustomClientConfig())"

helper = '''
    // [custom-build] read bundled assets/custom.txt, pass to native startServer
    private fun readCustomClientConfig(): String {
        return try {
            applicationContext.assets.open("custom.txt").bufferedReader().use { it.readText() }.trim()
        } catch (e: Exception) {
            ""
        }
    }
'''

if old_call not in src:
    sys.stderr.write("!! 未匹配到 FFI.startServer(configPath, \"\")（MainService.kt 与 1.4.9 不一致?）\n")
    sys.exit(1)
src = src.replace(old_call, new_call, 1)

anchor = "    override fun onCreate() {"
if anchor not in src:
    sys.stderr.write("!! 未找到 onCreate 锚点，跳过 helper 插入（startServer 仍已替换）\n")
else:
    src = src.replace(anchor, helper + anchor, 1)

open(p, "w", encoding="utf-8").write(src)
PY
  grep -q "readCustomClientConfig" "$MSVC" || { echo "!! MainService.kt 补丁失败" >&2; exit 1; }
  echo "== [OK] MainService.kt 已接通 assets/custom.txt"
else
  echo "== [SKIP] 未找到 $MSVC（非 Android 构建，跳过）"
fi

# ---------------------------------------------------------------------------
# 4. 生成 custom.txt（base64(JSON)），落盘源码根目录
# ---------------------------------------------------------------------------
python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tools/gen_custom_txt.py" \
  --config "$CFG" --out "$SRC_ROOT/custom.txt"

echo ""
echo "== 完成。custom.txt、config.rs、common.rs、MainService.kt 全部就绪 =="
