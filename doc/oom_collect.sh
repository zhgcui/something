###############################################
# 0. 判断是否发生过 OOM
###############################################
echo "[0] Checking if OOM has occurred..."
OUTDIR=/tmp/oom_collect_$(date +"%Y%m%d_%H%M%S")
mkdir -p $OUTDIR
OOM_LOG_RAW=$OUTDIR/oom_raw.log

# OOM 事件专属消息（覆盖内核OOM全链路，原文均可在内核源码 mm/oom_kill.c 中核实）：
#   "xxx invoked oom-killer"          —— OOM 路径被触发
#   "oom-kill:constraint=..."         —— OOM 事件概要行
#   "oom_reaper: reaped process ..."  —— OOM 受害者地址空间被回收
#   "Killed process ..."/"Kill process ..." —— 进程被杀（新/旧内核格式）
OOM_PATTERN='invoked oom-killer|oom-kill:constraint=|oom_reaper: reaped process|Kill(ed)? process'

journalctl -k --no-pager | grep -iE "$OOM_PATTERN" > $OOM_LOG_RAW
echo "DEBUG: OOM_LOG_RAW=$OOM_LOG_RAW"

# 判断方式：文件内容本身就是匹配出的OOM事件行，直接数非空行作为判断依据
OOM_COUNT=$(grep -c . $OOM_LOG_RAW 2>/dev/null)
[ -z "$OOM_COUNT" ] && OOM_COUNT=0
echo "DEBUG: matched_lines=$OOM_COUNT"

if [ "$OOM_COUNT" -gt 0 ]; then
    echo "OOM_OCCURRED=YES" > $OUTDIR/oom_status.log
    echo "OOM has occurred on this system." >> $OUTDIR/oom_status.log
    # 统计次数
    echo "OOM_COUNT=$OOM_COUNT" >> $OUTDIR/oom_status.log
    # 最近一次 OOM 时间
    LAST_KILL_LINE=$(grep -iE 'Kill(ed)? process' $OOM_LOG_RAW | tail -1)
    [ -z "$LAST_KILL_LINE" ] && LAST_KILL_LINE=$(tail -1 $OOM_LOG_RAW)
    LAST_OOM_TIME=$(printf '%s\n' "$LAST_KILL_LINE" | awk '{print $1,$2,$3}')
    echo "LAST_OOM_TIME=\"$LAST_OOM_TIME\"" >> $OUTDIR/oom_status.log
    # 最近一次被杀进程
    LAST_OOM_PROC="$LAST_KILL_LINE"
    echo "LAST_OOM_PROC=\"$LAST_OOM_PROC\"" >> $OUTDIR/oom_status.log

    echo "OOM_OCCURRED=YES OOM_COUNT=$OOM_COUNT"
else
    echo "OOM_OCCURRED=NO" > $OUTDIR/oom_status.log
    echo "No OOM events found in kernel logs." >> $OUTDIR/oom_status.log
    echo "OOM_OCCURRED=NO"
fi

###############################################
# 1. 收集内核 OOM 日志
###############################################
echo "[1] Collecting kernel OOM logs..."
cp $OOM_LOG_RAW $OUTDIR/oom_kernel.log
dmesg -T | grep -iE "$OOM_PATTERN" >> $OUTDIR/oom_kernel.log

###############################################
# 2. 收集 OOM 上下文（前后 20 行）
###############################################
echo "[2] Collecting OOM context..."
dmesg -T | grep -iE -A20 -B20 "$OOM_PATTERN" > $OUTDIR/oom_context.log

###############################################
# 3. 收集系统日志中资源相关错误
###############################################
echo "[3] Collecting system resource errors..."
journalctl -p err > $OUTDIR/system_errors.log

###############################################
# 完成
###############################################
echo "=== OOM Collect Completed ==="
echo "Output saved in: $OUTDIR"
echo "Check $OUTDIR/oom_status.log for OOM summary."
