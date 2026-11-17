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

//! L冬跑 —— 预设距离自动起停跑步 App v1.1.1
//! 为冬季厚手套场景设计：全程无需摘手套按键。
//! 流程：左中键/左下键调整数公里(1~42)，右下键调小数部分(+0.01) → 右上键(START)确认
//!       → 立即开始搜星 + 识别跑步姿态，"连续 60 秒跑步特征" 且 "GPS 已连接" 两者同时
//!       满足后自动开始计时计距 → 跑够预设距离自动停止并保存。
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
const DETECT_RATIO = 0.15;
const DETECT_SEC   = 60;   // 需连续识别的秒数

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

    // 运行期数据（GPS 速度积分）
    private var mRunDist    as Float  = 0.0;
    private var mRunStartMs as Number = 0;
    private var mLastPosMs  as Number = 0;
    private var mCurSpeed   as Float  = 0.0;

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
        mState = ST_MENU;
        WatchUi.requestUpdate();
    }

    //! 放弃当前跑步（停止并丢弃记录）
    public function cancelRun() as Void {
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
        try {
            Sensor.registerSensorDataListener(method(:onAccel),
                { :period => 1, :accelerometer => { :enabled => true, :sampleRate => 25 } });
        } catch (e) {
            System.println("registerSensorDataListener: " + e.getErrorMessage());
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
        try { Sensor.unregisterSensorDataListener(); } catch (e) { }
        mAccelBuf = [];
        mDetectSec = 0;
        mDistStr = "0.00"; mTimerStr = "0:00"; mHrStr = "--";
        mPaceStr = "--'--\""; mRemainStr = "--"; mAvgHr = 0;
        mHrSum = 0.0; mHrCount = 0;
        mRunDist = 0.0; mCurSpeed = 0.0;
        mRunStartMs = System.getTimer();
        mLastPosMs = mRunStartMs;
        try {
            mSession = ActivityRecording.createSession(
                { :name => "L冬跑", :sport => Activity.SPORT_RUNNING });
            if (mSession != null) {
                mSession.start();
            }
        } catch (e) {
            System.println("createSession: " + e.getErrorMessage());
        }
        // 开启 GPS 连续定位（计距用）
        try {
            Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
        } catch (e) {
            System.println("enableLocationEvents: " + e.getErrorMessage());
        }
        mState = ST_RUN;
        WatchUi.requestUpdate();
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

    //! GPS 定位回调：等待态更新定位标志；跑步态做速度积分累计距离
    public function onPosition(info as Position.Info) as Void {
        var hasFix = (info != null && info.position != null);
        if (mState == ST_ARMED) {
            mGpsFix = hasFix;   // 双条件之一：GPS 已连接
            return;
        }
        if (mState != ST_RUN || !hasFix) { return; }
        var now = System.getTimer();
        var dt = (now - mLastPosMs) / 1000.0;
        mLastPosMs = now;
        if (dt <= 0.0 || dt > 10.0) { return; }   // 异常间隔跳过
        var spd = null;
        if (info has :speed) { spd = info.speed; }
        if (spd != null && spd > 0.1) {
            mRunDist += spd * dt;
            mCurSpeed = spd;
        }
    }

    //! 加速度回调（每秒一批，约 25 个样本）
    public function onAccel(sensorData as Sensor.SensorData) as Void {
        var acc = sensorData.accelerometerData;
        if (acc == null) { return; }
        var xs = acc.x; var ys = acc.y; var zs = acc.z;
        if (xs == null || ys == null || zs == null) { return; }
        var n = xs.size();
        for (var i = 0; i < n; i++) {
            var x = xs[i] * 1.0;
            var y = ys[i] * 1.0;
            var z = zs[i] * 1.0;
            mAccelBuf.add(Math.sqrt(x * x + y * y + z * z));
        }
        if (mAccelBuf.size() > 400) {
            mAccelBuf = mAccelBuf.slice(mAccelBuf.size() - 200, mAccelBuf.size());
        }
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

    //! 从 SensorHistory 取当前心率
    private function pollHeartRate() as Void {
        if ((Toybox has :SensorHistory) && (SensorHistory has :getHeartRateHistory)) {
            var itr = null;
            try {
                itr = SensorHistory.getHeartRateHistory({ :period => 1, :order => SensorHistory.ORDER_NEWEST_FIRST });
            } catch (e) {
                return;
            }
            if (itr == null) { return; }
            var s = itr.next();
            if (s != null) {
                var hr = null;
                if (s has :heartRate) { hr = s.heartRate; }
                if (hr != null && hr > 0) {
                    mHrStr = hr.toNumber().toString();
                    mHrSum += hr;
                    mHrCount += 1;
                    mAvgHr = (mHrSum / mHrCount).toNumber();
                }
            }
        }
    }

    //! 每秒一次：更新时间 / 姿态识别 / 运行数据
    public function onTick() as Void {
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
            pollHeartRate();

            // 计时器
            var el = ((System.getTimer() - mRunStartMs) / 1000).toNumber();
            mTimerStr = formatDuration(el);

            // 距离与达标判断
            mDistStr = Lang.format("%.2f", [ mRunDist / 1000.0 ]);
            var target = mIntKm * 1000.0 + mDecH * 10.0;
            var rem = (target - mRunDist) / 1000.0;
            mRemainStr = rem > 0.0 ? Lang.format("%.2f", [ rem ]) : "0.00";
            if (mRunDist >= target) {
                finishRun();
                return;
            }

            // 配速
            if (mCurSpeed > 0.1) {
                mPaceStr = formatPace(mCurSpeed);
            }
        }

        WatchUi.requestUpdate();
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
                "长按UP 退出", Graphics.TEXT_JUSTIFY_CENTER);
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
                "双条件就绪自动开跑", Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(cxM, (h * 0.88).toNumber(), Graphics.FONT_TINY,
                "长按UP 退出", Graphics.TEXT_JUSTIFY_CENTER);
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

        // ---- ST_RUN：与 L跑步 v1.3.0 相同的三行布局 ----
        var r1 = numH;                  // 行1：心率 | 当前时间
        var r2 = tinyH + gap + numH;    // 行2：距离 | 计时器
        var r3 = tinyH + gap + numH;    // 行3：配速 | 剩余距离
        var total = r1 + r2 + r3 + gap * 2;
        var y = ((h - total) / 2).toNumber();

        var cxL = (w * 0.26).toNumber();
        var cxR = (w * 0.72).toNumber();

        // 行1：心率（左） | 当前时间（右）
        var hrCy = (y + numH * 0.5).toNumber();
        drawHeart(dc, (cxL - numH * 0.62).toNumber(), hrCy, numH * 0.9, Graphics.COLOR_BLACK);
        drawBold(dc, (cxL + numH * 0.35).toNumber(), y, mHrStr);
        drawBold(dc, cxR, y, mTimeStr);
        y += r1 + gap;

        // 行2：距离（左） | 计时器（右）
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cxL, y, Graphics.FONT_TINY, "距离", Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(cxR, y, Graphics.FONT_TINY, "计时器", Graphics.TEXT_JUSTIFY_CENTER);
        var v2y = (y + tinyH + gap).toNumber();
        drawBold(dc, cxL, v2y, mDistStr);
        drawBold(dc, cxR, v2y, mTimerStr);
        y += r2 + gap;

        // 行3：配速（左） | 剩余距离（右）
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cxL, y, Graphics.FONT_TINY, "配速", Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(cxR, y, Graphics.FONT_TINY, "剩余", Graphics.TEXT_JUSTIFY_CENTER);
        var v3y = (y + tinyH + gap).toNumber();
        drawBold(dc, cxL, v3y, mPaceStr);
        drawBold(dc, cxR, v3y, mRemainStr);
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
//! MENU:   左中键/左下键调整数公里(±1)，右下键(BACK)/LAP键调小数(+0.01)，
//!         右上键确认；长按 BACK 由系统直接退出应用
//! ARMED:  左键仍可改距离、右下键可改小数，右上键可跳过双条件立即开始（兜底），
//!         右下键返回菜单
//! RUN:    右上键手动结束（停止并保存），右下键放弃（停止并丢弃）
//! DONE:   确认/返回键回菜单
class LWRDelegate extends WatchUi.InputDelegate {

    private var _view as LWRView;

    public function initialize(view as LWRView) {
        InputDelegate.initialize();
        _view = view;
    }

    public function onKey(evt as KeyEvent) as Boolean {
        var key = evt.getKey();
        var st = _view.mState;

        if (st == ST_MENU) {
            if (WatchUi.KEY_MENU == key)  { _view.exitApp(); return true; }   // 长按 UP 退出应用
            if (WatchUi.KEY_UP == key)    { _view.intUp(); return true; }
            if (WatchUi.KEY_DOWN == key)  { _view.intDown(); return true; }
            if (WatchUi.KEY_LAP == key)   { _view.decNext(); return true; }
            if (WatchUi.KEY_ESC == key)   { _view.decNext(); return true; }
            if (WatchUi.KEY_ENTER == key) { _view.armRun(); return true; }
        } else if (st == ST_ARMED) {
            if (WatchUi.KEY_MENU == key)  { _view.exitApp(); return true; }   // 长按 UP 退出应用
            if (WatchUi.KEY_UP == key)    { _view.intUp(); return true; }
            if (WatchUi.KEY_DOWN == key)  { _view.intDown(); return true; }
            if (WatchUi.KEY_LAP == key)   { _view.decNext(); return true; }
            if (WatchUi.KEY_ENTER == key) { _view.startRun(); return true; }   // 兜底：立即开始
            if (WatchUi.KEY_ESC == key)   { _view.backToMenu(); return true; }
        } else if (st == ST_RUN) {
            if (WatchUi.KEY_ENTER == key) { _view.finishRun(); return true; }  // 手动结束（保存）
            if (WatchUi.KEY_ESC == key)   { _view.cancelRun(); return true; }  // 放弃（丢弃）
        } else if (st == ST_DONE) {
            if (WatchUi.KEY_ENTER == key || WatchUi.KEY_ESC == key) { _view.backToMenu(); return true; }
        }
        return false;
    }
}
