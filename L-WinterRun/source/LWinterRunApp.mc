import Toybox.Attention;
import Toybox.Application;
import Toybox.Activity;
import Toybox.ActivityRecording;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Position;
import Toybox.Sensor;
import Toybox.SensorHistory;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

//! L冬跑 —— 预设距离自动起停跑步 App v2.0.1
//! 为冬季厚手套场景设计：全程无需摘手套按键。
//! 流程：左中键/左下键调整数公里(1~42)，右下键(BACK)调小数部分(+0.01)
//!       → 右上键(START)确认
//!       → 立即开始搜星 + 识别跑步姿态，"连续 60 秒跑步特征" 且 "GPS 已连接" 两者同时
//!       满足后自动开始计时计距 → 跑够预设距离自动停止并保存。
//! 计距：GPS 相邻点 haversine 累加（不依赖 speed 字段）。
//! 振动：GPS 连接短震1 / 自动开表长震1 / 每整公里短震1 / 达标长震3（Attention.vibrate）。
//! 退出：长按UP(MENU键)任意状态退出（跑步中先保存）；选距离界面短按 BACK 退出。
//! 面板样式沿用 L跑步 v1.3.0：白底黑字加粗 + 顶部弧形刻度柱。
class LWinterRunApp extends Application.AppBase {

    private var mView as LWRView or Null = null;

    public function initialize() {
        AppBase.initialize();
    }

    public function getInitialView() as [Views] or [Views, InputDelegates] {
        var v = new LWRView();
        mView = v;
        return [ v, new LWRDelegate(v) ];
    }

    //! 退出时兜底：停止并保存会话，注销传感器与定位
    public function onStop(state as Dictionary or Null) as Void {
        if (mView != null) {
            mView.cleanup();
        }
    }
}

//! 状态常量
const ST_MENU  = 0;   // 调节目标距离
const ST_ARMED = 1;   // 已确认，等待「姿态识别 + GPS」双条件
const ST_RUN   = 2;   // 计时进行中
const ST_DONE  = 3;   // 完成（自动保存）

//! 目标距离：整数部分 1~42 公里（左中/左下键步进 1），
//! 小数部分 0.00~0.99（右下键每按一次 +0.01，到 0.99 后回到 0.00）
const KM_INT_MIN = 1;
const KM_INT_MAX = 42;

//! 跑步姿态判定：加速度幅值标准差 / 均值 比值阈值
//! 跑步时手臂摆动剧烈（比值约 0.25~0.45），走路约 0.08~0.15，静止接近 0
const DETECT_RATIO = 0.15;  // 跑步约 0.25~0.45，走路约 0.08~0.15
const DETECT_SEC   = 60;    // 需连续 60 秒达标，中断即重新计数

//! 主视图
class LWRView extends WatchUi.View {

    public var mState      as Number = ST_MENU;
    public var mIntKm      as Number = 5;      // 整数公里（1~42）
    public var mDecH       as Number = 0;      // 小数部分（0~99，单位 0.01 公里）
    public var mDetectSec  as Number = 0;      // 连续跑步特征秒数
    public var mGpsFix     as Boolean = false; // GPS 是否已定位
    public var mAvgHr      as Number = 0;

    private var mSession    as ActivityRecording.Session or Null = null;
    private var mTimer      as Timer.Timer or Null = null;

    private var mTimeStr    as String = "--:--";
    private var mHrStr      as String = "--";
    private var mDistStr    as String = "0.00";
    private var mTimerStr   as String = "0:00";
    private var mPaceStr    as String = "--'--\"";
    private var mRemainStr  as String = "--";
    private var mDoneDistStr  as String = "";
    private var mDoneTimeStr  as String = "";
    private var mDonePaceStr  as String = "";

    // 运行期数据（GPS haversine 逐点累加）
    private var mRunDist    as Float  = 0.0;
    private var mRunStartMs as Number = 0;
    private var mLastPosMs  as Number = 0;
    private var mCurSpeed   as Float  = 0.0;
    private var mLastLat    as Double or Null = null;   // 上一个 GPS 点
    private var mLastLon    as Double or Null = null;
    private var mLastKmMark as Number = 0;              // 已提示到的整公里数
    private var mLastHrCbMs as Number = 0;              // 最近一次传感器回调心率时刻（去重用）
    public  var mErrStr     as String = "";             // 等待态错误提示

    // 心率累计（用于平均心率）
    private var mHrSum    as Float  = 0.0;
    private var mHrCount  as Number = 0;

    private var mAccelBuf as Array<Float> = [];

    public function initialize() {
        View.initialize();
        mTimer = new Timer.Timer();
        mTimer.start(method(:onTick), 1000, true);
    }

    //! 退出兜底（App.onStop 调用）
    public function cleanup() as Void {
        if (mTimer != null) { mTimer.stop(); }
        try { Sensor.unregisterSensorDataListener(); } catch (e) { }
        try { Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition)); } catch (e) { }
        if (mSession != null) {
            try { mSession.stop(); } catch (e) { }
            try { mSession.save(); } catch (e) { }
            mSession = null;
        }
    }

    //! 返回菜单（从等待/完成状态）
    public function backToMenu() as Void {
        try { Sensor.unregisterSensorDataListener(); } catch (e) { }
        try { Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition)); } catch (e) { }
        if (mSession != null) {
            try { mSession.stop(); } catch (e) { }
            try { mSession.save(); } catch (e) { }
            mSession = null;
        }
        mDetectSec = 0;
        mGpsFix = false;
        mAccelBuf = [];
        mAvgHr = 0;
        mHrSum = 0.0;
        mHrCount = 0;
        mRunDist = 0.0;
        mLastLat = null;
        mLastLon = null;
        mLastKmMark = 0;
        mState = ST_MENU;
        mErrStr = "";
        WatchUi.requestUpdate();
    }

    //! 放弃当前跑步（停止并丢弃记录）
    public function cancelRun() as Void {
        // 注销传感器监听，避免回到菜单后仍持续回调
        try { Sensor.unregisterSensorDataListener(); } catch (e) { }
        mAccelBuf = [];
        mDetectSec = 0;
        try { Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition)); } catch (e) { }
        if (mSession != null) {
            try { mSession.stop(); } catch (e) { }
            try { mSession.discard(); } catch (e) { }
            mSession = null;
        }
        mState = ST_MENU;
        WatchUi.requestUpdate();
    }

    //! 退出应用（先清理传感器/定位/会话再退出）
    public function exitApp() as Void {
        cleanup();
        System.exit();
    }

    //! 整数公里 +1（循环 1~42）
    public function intUp() as Void {
        mIntKm = mIntKm >= KM_INT_MAX ? KM_INT_MIN : mIntKm + 1;
        WatchUi.requestUpdate();
    }

    //! 整数公里 -1（循环 1~42）
    public function intDown() as Void {
        mIntKm = mIntKm <= KM_INT_MIN ? KM_INT_MAX : mIntKm - 1;
        WatchUi.requestUpdate();
    }

    //! 小数部分 +0.01（循环 0.00~0.99）
    public function decNext() as Void {
        mDecH = (mDecH + 1) % 100;
        WatchUi.requestUpdate();
    }

    //! 目标距离显示字符串，如 "9.25"
    public function targetKmStr() as String {
        return Lang.format("$1$.$2$", [ mIntKm.toString(), mDecH.format("%02d") ]);
    }

    //! 确认目标 → 进入等待状态：立刻开始搜星 + 注册加速度监听
    public function armRun() as Void {
        mDetectSec = 0;
        mGpsFix = false;
        mAccelBuf = [];
        mErrStr = "";
        try {
            // 心跳间期必须显式启用，否则回调里 heartRateData 始终为 null
            Sensor.registerSensorDataListener(method(:onAccel),
                { :period => 1,
                  :accelerometer => { :enabled => true, :sampleRate => 25 },
                  :heartBeatIntervals => { :enabled => true } });
        } catch (e) {
            System.println("registerSensorDataListener: " + e.getErrorMessage());
            mErrStr = "REG: " + e.getErrorMessage();
        }
        // 提前开启 GPS 连续定位：搜星与姿态识别并行，双条件满足即开跑
        try {
            Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
        } catch (e) {
            System.println("enableLocationEvents: " + e.getErrorMessage());
        }
        mState = ST_ARMED;
        WatchUi.requestUpdate();
    }

    //! 姿态识别达标（或手动兜底）→ 创建跑步会话并开始
    public function startRun() as Void {
        // 保留传感器监听：RUN 态继续用它取实时心率（accelRatio 不再使用）
        mAccelBuf = [];
        mDetectSec = 0;
        mDistStr = "0.00"; mTimerStr = "0:00"; mHrStr = "--";
        mPaceStr = "--'--\""; mRemainStr = "--"; mAvgHr = 0;
        mHrSum = 0.0; mHrCount = 0; mLastHrCbMs = 0;
        mRunDist = 0.0; mCurSpeed = 0.0;
        mLastLat = null; mLastLon = null; mLastKmMark = 0;
        mRunStartMs = System.getTimer();
        mLastPosMs = mRunStartMs;
        var started = false;
        try {
            mSession = ActivityRecording.createSession(
                { :name => "L冬跑", :sport => Activity.SPORT_RUNNING });
            if (mSession != null) {
                started = mSession.start();
            }
        } catch (e) {
            System.println("createSession: " + e.getErrorMessage());
        }
        if (!started) {
            // 会话创建/启动失败：不进入跑步态，留在等待态并提示
            // （没有有效会话就无法保存记录，继续跑没有意义）
            mSession = null;
            mErrStr = "会话启动失败，无法保存";
            mState = ST_ARMED;
            WatchUi.requestUpdate();
            return;
        }
        // 开启 GPS 连续定位（计距用）
        try {
            Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
        } catch (e) {
            System.println("enableLocationEvents: " + e.getErrorMessage());
        }
        mState = ST_RUN;
        buzzStart();   // 开表长震1
        WatchUi.requestUpdate();
    }

    //! 跑步中退出应用：统一走 cleanup()（内含传感器注销、GPS 关闭、
    //! 会话停止+保存），保存路径唯一，不会出现重复保存
    public function exitRunSave() as Void {
        exitApp();
    }

    //! 达到预设距离（或手动）→ 停止并自动保存
    public function finishRun() as Void {
        try { Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition)); } catch (e) { }
        if (mSession != null) {
            try { mSession.stop(); } catch (e) { }
            try { mSession.save(); } catch (e) { }
            mSession = null;
        }
        mDoneDistStr = mDistStr;
        mDoneTimeStr = mTimerStr;
        mDonePaceStr = mPaceStr;
        mState = ST_DONE;
        WatchUi.requestUpdate();
    }

    //! GPS 定位回调：等待态更新定位标志（连上时短震提醒）；
    //! 跑步态用相邻 GPS 点 haversine 累加距离（不依赖 speed 字段）
    public function onPosition(info as Position.Info) as Void {
        if (info == null) { return; }          // 空回调防御
        try {
        var pos = info.position;
        if (pos == null) {
            if (mState == ST_ARMED) { mGpsFix = false; }   // 信号丢失，重新等待
            return;
        }
        if (mState == ST_ARMED) {
            if (!mGpsFix) {
                buzzGps();   // GPS 连接短震1
                mErrStr = "";
            }
            mGpsFix = true;
            return;
        }
        if (mState != ST_RUN) { return; }
        accumulateDistance(pos);
        } catch (e) { mErrStr = "GPS: " + e.getErrorMessage(); }
    }

    //! 跑步态：用相邻 GPS 点 haversine 累加距离（不依赖 speed 字段）
    private function accumulateDistance(pos as Position.Location) as Void {
        var deg = pos.toDegrees();
        if (deg == null || deg.size() < 2) { return; }
        var lat = deg[0] as Double;
        var lon = deg[1] as Double;
        var now = System.getTimer();
        var dt = (now - mLastPosMs) / 1000.0;
        if (mLastLat != null && mLastLon != null) {
            var d = haversineM(mLastLat, mLastLon, lat, lon);
            // 单点跳变保护：>200m 视为漂移丢弃；
            // 但若间隔较长（GPS 短暂失联后恢复），按实际速度放宽上限，避免漏计真实距离
            var accept = d >= 0.0 && d < 200.0;
            if (!accept && dt > 5.0 && dt < 120.0 && d / dt < 8.0) {
                accept = true;   // 失联恢复：折算速度 < 8m/s 即采信
            }
            if (accept) {
                mRunDist += d;
                if (dt > 0.5 && dt < 60.0 && d > 0.5) {
                    mCurSpeed = (d / dt) as Float;   // 用于配速
                }
            }
        }
        mLastPosMs = now;
        mLastLat = lat;
        mLastLon = lon;
    }

    //! 传感器回调（每秒一批）：加速度样本 → 姿态识别；RR间期 → 换算心率
    public function onAccel(sensorData as Sensor.SensorData) as Void {
        try {
        // 双通道心率之一：由心跳间期（RR interval，毫秒）换算实时心率
        var hd = sensorData.heartRateData;
        if (hd != null) {
            var iv = hd.heartBeatIntervals;
            if (iv != null && iv.size() > 0) {
                var sum = 0.0;
                for (var j = 0; j < iv.size(); j++) {
                    sum += iv[j].toFloat();
                }
                var avgMs = sum / iv.size();
                if (avgMs > 0.0) {
                    var bpm = (60000.0 / avgMs).toNumber();
                    if (bpm >= 30 && bpm <= 250) {
                        applyHeartRate(bpm);
                    }
                }
            }
        }
        var acc = sensorData.accelerometerData;
        if (acc == null) { return; }
        var xs = acc.x; var ys = acc.y; var zs = acc.z;
        if (xs == null || ys == null || zs == null) { return; }
        var n = xs.size();
        for (var i = 0; i < n; i++) {
            var x = xs[i].toFloat();
            var y = ys[i].toFloat();
            var z = zs[i].toFloat();
            mAccelBuf.add(Math.sqrt(x * x + y * y + z * z) as Float);
        }
        if (mAccelBuf.size() > 400) {
            mAccelBuf = mAccelBuf.slice(mAccelBuf.size() - 200, mAccelBuf.size());
        }
        } catch (e) { mErrStr = "SEN: " + e.getErrorMessage(); }
    }

    //! 心率样本落账（两条通道共用）
    private function applyHeartRate(hr as Numeric) as Void {
        var hrN = hr.toNumber();
        mHrStr = hrN.toString();
        mHrSum += hrN * 1.0;
        mHrCount += 1;
        mAvgHr = (mHrSum / mHrCount).toNumber();
        mLastHrCbMs = System.getTimer();
    }

    //! 加速度幅值的标准差 / 均值（单位无关，跑步显著大于走路与静止）
    private function accelRatio() as Numeric or Null {
        var n = mAccelBuf.size();
        if (n < 10) { return null; }
        var sum = 0.0;
        var sum2 = 0.0;
        for (var i = 0; i < n; i++) {
            var v = mAccelBuf[i];
            sum  += v;
            sum2 += v * v;
        }
        var mean = sum / n;
        if (mean <= 0.0) { return null; }
        var varr = sum2 / n - mean * mean;
        if (varr < 0.0) { varr = 0.0; }
        return (Math.sqrt(varr) / mean).toFloat();
    }

    //! 从 SensorHistory 取当前心率（备用通道）
    private function pollHeartRate() as Void {
        if ((Toybox has :SensorHistory) && (SensorHistory has :getHeartRateHistory)) {
            var itr = null;
            try {
                itr = SensorHistory.getHeartRateHistory({ :period => 1, :order => SensorHistory.ORDER_NEWEST_FIRST });
            } catch (e) {
                return;
            }
            // 取最近一个有效样本
            for (var i = 0; i < 5; i++) {
                var s = itr.next();
                if (s == null) { break; }
                if (s has :heartRate) {
                    var hr = s.heartRate;
                    if (hr != null && hr > 0) {
                        applyHeartRate(hr as Numeric);
                        break;
                    }
                }
            }
        }
    }

    //! 相邻两个 GPS 点的地面距离（米），haversine 公式
    private function haversineM(lat1 as Double, lon1 as Double, lat2 as Double, lon2 as Double) as Float {
        var dLat = Math.toRadians(lat2 - lat1);
        var dLon = Math.toRadians(lon2 - lon1);
        var a = Math.sin(dLat / 2.0) * Math.sin(dLat / 2.0)
              + Math.cos(Math.toRadians(lat1)) * Math.cos(Math.toRadians(lat2))
              * Math.sin(dLon / 2.0) * Math.sin(dLon / 2.0);
        if (a < 0.0) { a = 0.0; }
        if (a > 1.0) { a = 1.0; }
        var c = 2.0 * Math.atan2(Math.sqrt(a), Math.sqrt(1.0 - a));
        return (6371000.0 * c).toFloat();
    }

    //! ---- 振动提醒（Attention.vibrate）----
    //! profile = [强度 dutyCycle(0~100 百分比), 持续毫秒]，强度 0 为停顿
    private function buzz(pattern as Array<Attention.VibeProfile>) as Void {
        try {
            if ((Toybox has :Attention) && (Attention has :vibrate)) {
                Attention.vibrate(pattern);
            }
        } catch (e) { }
    }

    //! GPS 连接：短震 1 次
    private function buzzGps() as Void {
        buzz([ new Attention.VibeProfile(100, 150) as Attention.VibeProfile ]);
    }

    //! 自动开表：长震 1 次
    private function buzzStart() as Void {
        buzz([ new Attention.VibeProfile(100, 800) as Attention.VibeProfile ]);
    }

    //! 每跑满 1 整公里：短震 1 次
    private function buzzKm() as Void {
        buzz([ new Attention.VibeProfile(100, 150) as Attention.VibeProfile ]);
    }

    //! 达到目标距离：长震 3 次
    private function buzzGoal() as Void {
        buzz([
            new Attention.VibeProfile(100, 500) as Attention.VibeProfile,
            new Attention.VibeProfile(0, 200) as Attention.VibeProfile,
            new Attention.VibeProfile(100, 500) as Attention.VibeProfile,
            new Attention.VibeProfile(0, 200) as Attention.VibeProfile,
            new Attention.VibeProfile(100, 500) as Attention.VibeProfile
        ]);
    }

    //! 每秒一次：更新时间 / 姿态识别 / 运行数据
    public function onTick() as Void {
        try {
        var t = System.getClockTime();
        mTimeStr = Lang.format("$1$:$2$", [ t.hour.format("%02d"), t.min.format("%02d") ]);

        if (mState == ST_ARMED) {
            // 这一秒的样本 → 判定是否跑步姿态
            var ratio = accelRatio();
            mAccelBuf = [];   // 只看最近 1 秒
            if (ratio != null && ratio > DETECT_RATIO) {
                if (mDetectSec < DETECT_SEC) {
                    mDetectSec += 1;
                }
            } else {
                mDetectSec = 0;   // 必须连续，中断即重新计数
            }
            // 双条件同时满足才开跑：连续姿态识别达标 + GPS 已连接
            if (mDetectSec >= DETECT_SEC && mGpsFix) {
                startRun();
            }
        } else if (mState == ST_RUN) {
            // 备用通道：仅当传感器回调超过 3 秒没送来心率时才轮询历史，
            // 避免同一份历史样本被两条通道重复计入平均值
            if (System.getTimer() - mLastHrCbMs > 3000) {
                pollHeartRate();
            }

            // 计时器
            var el = ((System.getTimer() - mRunStartMs) / 1000).toNumber();
            mTimerStr = formatDuration(el);

            // 距离与达标判断（%.2f 用数值 format 方法，Lang.format 不认这个写法）
            mDistStr = (mRunDist / 1000.0).format("%.2f");
            var target = mIntKm * 1000.0 + mDecH * 10.0;
            var rem = (target - mRunDist) / 1000.0;
            mRemainStr = rem > 0.0 ? rem.format("%.2f") : "0.00";
            if (mRunDist >= target) {
                buzzGoal();    // 达标长震3
                finishRun();
                return;
            }

            // 每跑满 1 整公里：短震提醒
            var kmNow = (mRunDist / 1000.0).toNumber();
            if (kmNow >= mLastKmMark + 1) {
                mLastKmMark = kmNow;
                buzzKm();
            }

            // 配速
            if (mCurSpeed > 0.1) {
                mPaceStr = formatPace(mCurSpeed);
            }
        }

        WatchUi.requestUpdate();
        } catch (e) { mErrStr = "TICK: " + e.getErrorMessage(); WatchUi.requestUpdate(); }
    }

    private function formatDuration(sec as Number) as String {
        if (sec >= 3600) {
            return Lang.format("$1$:$2$:$3$", [
                (sec / 3600).toNumber().toString(),
                ((sec % 3600) / 60).toNumber().format("%02d"),
                (sec % 60).toNumber().format("%02d")
            ]);
        }
        return Lang.format("$1$:$2$", [
            (sec / 60).toNumber().toString(),
            (sec % 60).toNumber().format("%02d")
        ]);
    }

    private function formatPace(spd as Float) as String {
        var spk = (1000.0 / spd).toNumber();
        return Lang.format("$1$'$2$\"", [
            (spk / 60).toNumber().toString(),
            (spk % 60).toNumber().format("%02d")
        ]);
    }

    //! 平均心率（或进度值）→ 区间颜色
    //! ≤116 灰 / 117-135 蓝 / 136-150 绿 / 151-169 橙 / ≥170 红
    private function zoneColor(hr as Number) as Number {
        if (hr <= 116) { return Graphics.COLOR_DK_GRAY; }
        if (hr <= 135) { return Graphics.COLOR_BLUE; }
        if (hr <= 150) { return Graphics.COLOR_GREEN; }
        if (hr <= 169) { return Graphics.COLOR_ORANGE; }
        return Graphics.COLOR_RED;
    }

    public function onLayout(dc as Dc) as Void {
    }

    //! 绘制（白底黑字加粗，沿用 L跑步 v1.3.0 风格）
    public function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();
        var cxM = (w / 2).toNumber();
        var cyM = (h / 2).toNumber();

        // ---- 顶部弧形刻度柱 ----
        if (mState == ST_MENU) {
            drawZoneArc(dc, cxM, cyM, h, 200);              // 全彩（装饰）
        } else if (mState == ST_ARMED) {
            var pseudo = 90.0 + 110.0 * mDetectSec / DETECT_SEC;   // 识别进度映射到色带
            drawZoneArc(dc, cxM, cyM, h, pseudo.toNumber());
        } else if (mState == ST_RUN) {
            drawZoneArc(dc, cxM, cyM, h, mAvgHr);           // 按平均心率
        } else {
            drawZoneArc(dc, cxM, cyM, h, 200);              // 完成态全彩
        }

        var numH  = dc.getFontHeight(Graphics.FONT_NUMBER_MEDIUM);
        var tinyH = dc.getFontHeight(Graphics.FONT_TINY);
        var gap   = 4;

        if (mState == ST_MENU) {
            // 调节目标距离（整数 + 小数）
            var y0 = (h * 0.30).toNumber();
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cxM, (h * 0.13).toNumber(), Graphics.FONT_TINY, "L冬跑", Graphics.TEXT_JUSTIFY_CENTER);

            drawBold(dc, cxM, y0, targetKmStr());

            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cxM, (y0 + numH + gap).toNumber(), Graphics.FONT_TINY, "公里", Graphics.TEXT_JUSTIFY_CENTER);

            dc.drawText(cxM, (h * 0.62).toNumber(), Graphics.FONT_TINY,
                "UP/DOWN 整数公里", Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(cxM, (h * 0.70).toNumber(), Graphics.FONT_TINY,
                "BACK 调小数 0.01", Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(cxM, (h * 0.78).toNumber(), Graphics.FONT_TINY,
                "START 确认", Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(cxM, (h * 0.87).toNumber(), Graphics.FONT_TINY,
                mErrStr != "" ? mErrStr : "长按 UP 退出", Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        if (mState == ST_ARMED) {
            // 等待「姿态识别 + GPS 连接」双条件
            var y0 = (h * 0.28).toNumber();
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cxM, (h * 0.13).toNumber(), Graphics.FONT_TINY, "目标距离", Graphics.TEXT_JUSTIFY_CENTER);

            drawBold(dc, cxM, y0, targetKmStr() + " km");

            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cxM, (h * 0.62).toNumber(), Graphics.FONT_TINY,
                "姿态识别 " + mDetectSec + "/60 秒", Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(cxM, (h * 0.70).toNumber(), Graphics.FONT_TINY,
                mGpsFix ? "GPS 已连接" : "GPS 搜星中…", Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(cxM, (h * 0.80).toNumber(), Graphics.FONT_TINY,
                mErrStr != "" ? mErrStr : "双条件就绪自动开跑", Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(cxM, (h * 0.88).toNumber(), Graphics.FONT_TINY,
                "BACK 返回 · 长按UP 退出", Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        if (mState == ST_DONE) {
            // 完成摘要
            var y0 = (h * 0.28).toNumber();
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cxM, (h * 0.15).toNumber(), Graphics.FONT_TINY, "目标达成", Graphics.TEXT_JUSTIFY_CENTER);

            drawBold(dc, cxM, y0, mDoneDistStr + " km");
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cxM, (y0 + numH + gap).toNumber(), Graphics.FONT_TINY,
                "用时 " + mDoneTimeStr + " · 配速 " + mDonePaceStr, Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(cxM, (h * 0.72).toNumber(), Graphics.FONT_TINY,
                "已自动保存", Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(cxM, (h * 0.80).toNumber(), Graphics.FONT_TINY,
                "START 返回", Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        // ---- ST_RUN：圆形屏安全区三行布局（列位收拢到圆内，底部行用小号字体防出圈）----
        var cxL = (w * 0.32).toNumber();
        var cxR = (w * 0.68).toNumber();
        var numSH = dc.getFontHeight(Graphics.FONT_NUMBER_MILD);

        // 行1：心率（左） | 当前时间（右，小号字体保证圆内完整）
        var y1 = (h * 0.20).toNumber();
        var hrCy = (y1 + numH * 0.5).toNumber();
        drawHeart(dc, (cxL - numH * 0.62).toNumber(), hrCy, numH * 0.9, Graphics.COLOR_BLACK);
        drawBold(dc, (cxL + numH * 0.35).toNumber(), y1, mHrStr);
        drawBoldSmall(dc, cxR, (y1 + (numH - numSH) / 2).toNumber(), mTimeStr);

        // 行2：距离 | 计时器（中段，屏幕最宽处，可用中号字体）
        var y2 = (h * 0.42).toNumber();
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cxL, y2, Graphics.FONT_TINY, "距离", Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(cxR, y2, Graphics.FONT_TINY, "计时器", Graphics.TEXT_JUSTIFY_CENTER);
        var v2y = (y2 + tinyH + gap).toNumber();
        drawBold(dc, cxL, v2y, mDistStr);
        drawBold(dc, cxR, v2y, mTimerStr);

        // 行3：配速 | 剩余（屏幕下缘收窄处，用小号字体）
        var y3 = (h * 0.68).toNumber();
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cxL, y3, Graphics.FONT_TINY, "配速", Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(cxR, y3, Graphics.FONT_TINY, "剩余", Graphics.TEXT_JUSTIFY_CENTER);
        var v3y = (y3 + tinyH + gap).toNumber();
        drawBoldSmall(dc, cxL, v3y, mPaceStr);
        drawBoldSmall(dc, cxR, v3y, mRemainStr);

        if (mErrStr != "") {
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cxM, (h * 0.94).toNumber(), Graphics.FONT_TINY, mErrStr, Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    //! 数值文字加重加粗：横向 3 遍 + 纵向 2 遍叠印
    private function drawBold(dc as Dc, x as Number, y as Number, text as String) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        for (var dx = 0; dx < 3; dx++) {
            for (var dy = 0; dy < 2; dy++) {
                dc.drawText(x + dx, y + dy, Graphics.FONT_NUMBER_MEDIUM, text, Graphics.TEXT_JUSTIFY_CENTER);
            }
        }
    }

    //! 小号数值文字加重加粗（底部行防出圈用）
    private function drawBoldSmall(dc as Dc, x as Number, y as Number, text as String) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        for (var dx = 0; dx < 3; dx++) {
            for (var dy = 0; dy < 2; dy++) {
                dc.drawText(x + dx, y + dy, Graphics.FONT_NUMBER_MILD, text, Graphics.TEXT_JUSTIFY_CENTER);
            }
        }
    }

    //! 顶部刻度弧：15 段，细 → 粗，灰→蓝→绿→橙→红；只画到伪心率/进度对应段
    private function drawZoneArc(dc as Dc, cx as Number, cy as Number, h as Number, pseudoHr as Number) as Void {
        if (pseudoHr <= 0) { return; }

        var n = 15;
        var aStart = -152.0;
        var aEnd   = -28.0;
        var step   = (aEnd - aStart) / n;
        var segAng = step * 0.72;

        var rOutBase = h * 0.470;
        var tMin     = h * 0.012;
        var tMax     = h * 0.040;
        var hrMin    = 90.0;
        var hrMax    = 200.0;

        for (var i = 0; i < n; i++) {
            var hrSeg = (hrMin + (hrMax - hrMin) * i / (n - 1)).toNumber();
            if (hrSeg > pseudoHr) { continue; }

            var f     = i.toFloat() / (n - 1);
            var thick = tMin + (tMax - tMin) * f;
            var rOut  = rOutBase;
            var rIn   = rOutBase - thick;

            dc.setColor(zoneColor(hrSeg), Graphics.COLOR_TRANSPARENT);

            var d0 = aStart + step * i;
            var dm = d0 + segAng * 0.5;
            var d1 = d0 + segAng;

            var a0 = d0 * Math.PI / 180.0;
            var am = dm * Math.PI / 180.0;
            var a1 = d1 * Math.PI / 180.0;

            var o0x = (cx + rOut * Math.cos(a0)).toNumber();
            var o0y = (cy + rOut * Math.sin(a0)).toNumber();
            var omx = (cx + rOut * Math.cos(am)).toNumber();
            var omy = (cy + rOut * Math.sin(am)).toNumber();
            var o1x = (cx + rOut * Math.cos(a1)).toNumber();
            var o1y = (cy + rOut * Math.sin(a1)).toNumber();
            var i1x = (cx + rIn * Math.cos(a1)).toNumber();
            var i1y = (cy + rIn * Math.sin(a1)).toNumber();
            var imx = (cx + rIn * Math.cos(am)).toNumber();
            var imy = (cy + rIn * Math.sin(am)).toNumber();
            var i0x = (cx + rIn * Math.cos(a0)).toNumber();
            var i0y = (cy + rIn * Math.sin(a0)).toNumber();

            dc.fillPolygon([
                [ o0x, o0y ], [ omx, omy ], [ o1x, o1y ],
                [ i1x, i1y ], [ imx, imy ], [ i0x, i0y ]
            ]);
        }
    }

    //! 画一个实心小爱心（两个圆 + 三角）
    private function drawHeart(dc as Dc, cx as Number, cy as Number, s as Float, color as Number) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        var r = (s * 0.5).toNumber();
        var top = (cy - s * 0.25).toNumber();
        dc.fillCircle((cx - r).toNumber(), top, r);
        dc.fillCircle((cx + r).toNumber(), top, r);
        dc.fillPolygon([
            [ (cx - s * 0.62).toNumber(), (cy - s * 0.05).toNumber() ],
            [ (cx + s * 0.62).toNumber(), (cy - s * 0.05).toNumber() ],
            [ cx, (cy + s * 0.72).toNumber() ]
        ]);
    }
}

//! 按键处理
//! MENU:   UP/DOWN 调整数公里(±1)，右下键(BACK/LAP)调小数(+0.01)，右上键确认，
//!         长按 UP(MENU键) 退出应用
//! ARMED:  左键仍可改距离、LAP 键改小数，右上键可跳过双条件立即开始（兜底），
//!         短按 BACK 返回菜单，长按 UP 退出应用
//! RUN:    右上键手动结束（停止并保存），短按 BACK 放弃（停止并丢弃），
//!         长按 UP 保存并退出应用
//! DONE:   确认/返回键回菜单，长按 UP 退出应用
class LWRDelegate extends WatchUi.InputDelegate {

    private var _view as LWRView;

    public function initialize(view as LWRView) {
        InputDelegate.initialize();
        _view = view;
    }

    public function onKey(evt as KeyEvent) as Boolean {
        try {
        var key = evt.getKey();
        var st = _view.mState;

        if (st == ST_MENU) {
            if (WatchUi.KEY_MENU == key)  { _view.exitApp(); return true; }   // 长按 UP 退出
            if (WatchUi.KEY_UP == key)    { _view.intUp(); return true; }
            if (WatchUi.KEY_DOWN == key)  { _view.intDown(); return true; }
            // fenix7x 是 5 键机型，右下键在程序里发的是 BACK(KEY_ESC) 而非 LAP，
            // 因此小数步进改用右下键(BACK)；6 键机型的独立 LAP 键也一并支持
            if (WatchUi.KEY_ESC == key)   { _view.decNext(); return true; }
            if (WatchUi.KEY_LAP == key)   { _view.decNext(); return true; }
            if (WatchUi.KEY_ENTER == key) { _view.armRun(); return true; }
        } else if (st == ST_ARMED) {
            if (WatchUi.KEY_MENU == key)  { _view.exitApp(); return true; }   // 长按 UP 退出
            if (WatchUi.KEY_UP == key)    { _view.intUp(); return true; }
            if (WatchUi.KEY_DOWN == key)  { _view.intDown(); return true; }
            if (WatchUi.KEY_LAP == key)   { _view.decNext(); return true; }
            if (WatchUi.KEY_ENTER == key) { _view.startRun(); return true; }   // 兜底：立即开始
            if (WatchUi.KEY_ESC == key)   { _view.backToMenu(); return true; }
        } else if (st == ST_RUN) {
            if (WatchUi.KEY_MENU == key)  { _view.exitRunSave(); return true; }  // 长按 UP：保存并退出
            if (WatchUi.KEY_ENTER == key) { _view.finishRun(); return true; }  // 手动结束（保存）
            if (WatchUi.KEY_ESC == key)   { _view.cancelRun(); return true; }  // 放弃（丢弃）
        } else if (st == ST_DONE) {
            if (WatchUi.KEY_MENU == key)  { _view.exitApp(); return true; }   // 长按 UP 退出
            if (WatchUi.KEY_ENTER == key || WatchUi.KEY_ESC == key) { _view.backToMenu(); return true; }
        }
        } catch (e) { _view.mErrStr = "KEY: " + e.getErrorMessage(); WatchUi.requestUpdate(); }
        return false;
    }
}
