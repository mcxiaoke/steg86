#!/usr/bin/env bash
#
# steg86 回归测试（Windows / Git-Bash 友好）
#
# 验证两件事：
#   1) 透明性：对一组固定的真实 exe 注入数据后，其 --help 运行结果（退出码 /
#      stdout / stderr / 文件大小）与注入前逐字节一致（仅程序自引用的名字/路径
#      这类 argv[0] 差异会被归一化掉，与注入无关）。
#   2) 提取正确性：注入的数据能逐字节地提取回来（文本 + 特殊字节 + 1KB 随机二进制）。
#
# 固定样本（请保留 temp/tools 下的这 10 个 exe，其余可删除）：
#   steg86  rg  busybox  cwebp  sqlite3  nasm  rhash  7z  rclone  coreutils
#
# 用法：
#   test/regression-tools.sh
# 可选环境变量：
#   STEG86_EXE         steg86 可执行文件路径（默认 ../target/release/steg86.exe，缺失则自动构建）
#   STEG86_TEST_TOOLS_DIR  样本 exe 所在目录（默认 ../temp/tools）

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STEG86_EXE="${STEG86_EXE:-${REPO_DIR}/target/release/steg86.exe}"
TOOLS_DIR="${STEG86_TEST_TOOLS_DIR:-${REPO_DIR}/temp/tools}"
WORK_DIR="${REPO_DIR}/temp/regression"

# 固定的 10 个样本（无 .exe 后缀）
TOOLS=(steg86 rg busybox cwebp sqlite3 nasm rhash 7z rclone coreutils)

function die {
  >&2 echo "Fatal: ${*}"
  exit 1
}

function steg86 {
  "$STEG86_EXE" "${@}"
}

# 把输出里“exe 自引用的名字/路径”替换成占位符，消除 argv[0] 带来的假差异。
# 对 orig/steg 两侧用同样的替换，保证只有真正的注入差异会保留下来。
# 只匹配 "_steg" / "_orig" 这两个我们特有的标记（无论其后是否带 .exe 或路径前缀），
# 例如 coreutils 会把 argv[0] 去掉 .exe 后的 coreutils_orig 当作子程序名打印，
# 而 sqlite3 / steg86 会打印完整路径或带 .exe 的名字，统一替换即可消除。
function norm {
  local name="$1" f="$2"
  sed -e "s#${name}_steg#STEG86TEST#g" -e "s#${name}_orig#STEG86TEST#g" "$f" > "$f.n"
}

function run_help {
  local exe="$1" out="$2" err="$3"
  if command -v timeout >/dev/null 2>&1; then
    timeout 60 "$exe" --help >"$out" 2>"$err"
  else
    "$exe" --help >"$out" 2>"$err"
  fi
  return $?
}

# 透明性：注入前后运行 --help 是否一致
function runtime_check {
  local name="$1"
  local orig="${WORK_DIR}/${name}_orig.exe"
  local steg="${WORK_DIR}/${name}_steg.exe"

  cp "${TOOLS_DIR}/${name}.exe" "${orig}" || { echo "  runtime: SKIP (copy failed)"; return 2; }
  steg86 embed "${orig}" "${steg}" < "${WORK_DIR}/msg_special.bin" >/dev/null 2>&1 \
    || { echo "  runtime: SKIP (embed failed)"; rm -f "${orig}"; return 2; }

  local osz ssz
  osz=$(stat -c %s "${orig}")
  ssz=$(stat -c %s "${steg}")

  run_help "${orig}" "${WORK_DIR}/${name}_o.out" "${WORK_DIR}/${name}_o.err"; local oR=$?
  run_help "${steg}" "${WORK_DIR}/${name}_s.out" "${WORK_DIR}/${name}_s.err"; local sR=$?

  norm "${name}" "${WORK_DIR}/${name}_o.out"
  norm "${name}" "${WORK_DIR}/${name}_s.out"
  norm "${name}" "${WORK_DIR}/${name}_o.err"
  norm "${name}" "${WORK_DIR}/${name}_s.err"

  local ok=1
  [[ "$oR" = "$sR" ]] || ok=0
  [[ "$osz" = "$ssz" ]] || ok=0
  diff -q "${WORK_DIR}/${name}_o.out.n" "${WORK_DIR}/${name}_s.out.n" >/dev/null || ok=0
  diff -q "${WORK_DIR}/${name}_o.err.n" "${WORK_DIR}/${name}_s.err.n" >/dev/null || ok=0

  if [[ $ok -eq 1 ]]; then
    echo "  runtime: PASS (rc=${oR} size=${osz}B==${ssz}B --help identical)"
  else
    echo "  runtime: FAIL (rc ${oR}/${sR} size ${osz}/${ssz})"
    diff "${WORK_DIR}/${name}_o.out.n" "${WORK_DIR}/${name}_s.out.n" | head -8
    diff "${WORK_DIR}/${name}_o.err.n" "${WORK_DIR}/${name}_s.err.n" | head -8
  fi
  # ok==1 表示通过，对应返回码 0；ok==0 表示失败，对应返回码 1
  return $((1 - ok))
}

# 提取正确性：注入某消息，再提取并与原始消息逐字节比较
function extract_check {
  local name="$1" msg="$2"
  local steg="${WORK_DIR}/${name}_x_$(basename "${msg}" .bin).exe"
  local out="${WORK_DIR}/${name}_x_$(basename "${msg}" .bin).out"

  steg86 embed "${WORK_DIR}/${name}_orig.exe" "${steg}" < "${msg}" >/dev/null 2>&1 \
    || { echo "  extract[$(basename "${msg}")]: SKIP (embed failed)"; return 2; }
  steg86 extract "${steg}" > "${out}" 2>/dev/null \
    || { echo "  extract[$(basename "${msg}")]: FAIL (extract errored)"; return 1; }

  if cmp -s "${msg}" "${out}"; then
    echo "  extract[$(basename "${msg}")]: PASS ($(stat -c %s "${msg}") bytes exact)"
    return 0
  else
    echo "  extract[$(basename "${msg}")]: FAIL (bytes differ)"
    cmp "${msg}" "${out}" | head -5
    return 1
  fi
}

# --- 准备 ---
[[ -d "${TOOLS_DIR}" ]] || die "TOOLS_DIR not found: ${TOOLS_DIR}"
if [[ ! -f "${STEG86_EXE}" ]]; then
  echo "steg86 not built, building release..."
  (cd "${REPO_DIR}" && cargo build --release) || die "build failed"
fi
[[ -f "${STEG86_EXE}" ]] || die "steg86 executable missing: ${STEG86_EXE}"

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

# 构造测试消息：一个含换行/制表符/回车/NUL/0xFF 的文本消息，外加 1KB 随机二进制
printf 'steg86 regression test\nline2\tTAB\r\nNUL\x00byte\xFFend' > "${WORK_DIR}/msg_special.bin"
if command -v head >/dev/null 2>&1; then
  head -c 1024 /dev/urandom > "${WORK_DIR}/msg_rand.bin" 2>/dev/null \
    || head -c 1024 /dev/null > "${WORK_DIR}/msg_rand.bin"
fi
[[ -s "${WORK_DIR}/msg_rand.bin" ]] || printf 'random-fallback-0123456789' > "${WORK_DIR}/msg_rand.bin"

echo "steg86 regression test"
echo "  tools dir : ${TOOLS_DIR}"
echo "  steg86    : ${STEG86_EXE}"
echo

total=0
pass=0
for name in "${TOOLS[@]}"; do
  echo "=== ${name} ==="
  if [[ ! -f "${TOOLS_DIR}/${name}.exe" ]]; then
    echo "  SKIP (not found in tools dir)"
    continue
  fi
  total=$((total + 1))

  rc=0
  runtime_check "${name}"; rc=$((rc + $?))
  extract_check "${name}" "${WORK_DIR}/msg_special.bin"; rc=$((rc + $?))
  extract_check "${name}" "${WORK_DIR}/msg_rand.bin"; rc=$((rc + $?))

  if [[ $rc -eq 0 ]]; then
    pass=$((pass + 1))
    echo "  => PASS"
  else
    echo "  => FAIL (rc=${rc})"
  fi
done

rm -rf "${WORK_DIR}"

echo
echo "Summary: ${pass}/${total} tools passed"
[[ $pass -eq $total ]] || exit 1
