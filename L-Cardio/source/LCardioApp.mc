import Toybox.Application;
import Toybox.Activity;
import Toybox.ActivityMonitor;
import Toybox.ActivityRecording;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Sensor;
import Toybox.SensorHistory;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

//! 有氧运动+ v1.0.0
//! 借鉴 GitHub 成熟做法（wwarby/walker、adamjakab/iHIIT、roelofk/HeartRateRunner）：
//! 屏幕常驻当前时钟（原生有氧运动缺的就是它）+ 实时心率三通道取数（冬跑 v2.0.x 已验证方案），
//! 结束时保存为 有氧训练 类型的训练记录（SPORT_TRAINING + SUB_SPORT_CARDIO_TRAINING）。
//!
//! 界面（白底黑字加粗，顶部心率区间弧）：
//!   行1：心率（大） | 当前时间（大，常驻）
//!   行2：运动时间   | 卡路里（心率估算法）
//!   行3：平均心率
//! 按键（fenix7x 真机键位）：
//!   右上 START：开始 / 暂停 / 继续
//!   右下 BACK ：运动中或暂停中按 → 结束并保存记录
//!   长按 UP   ：退出应用（运动中先保存再退出）

const ST_IDLE  = 0;    // 未开始
const ST_RUN   = 1;    // 运动中
const ST_PAUSE = 2;    // 暂停
const ST_DONE  = 3;    // 已保存，显示摘要

//! 卡路里估算系数：kcal/秒 ≈ 心率 × K / 60
//! 按体重 70kg 有氧运动常见心率-能耗关系取 K = 0.0117（估算值，仅供参考）
const KCAL_PER_HR_SEC = 0.000195;

class LCardioApp extends Application.AppBase {

    public function initialize() {
        AppBase.initialize();
    }

    public function getInitialView() as [Views] or [Views, InputDelegates] {
        var view = new LCardioView();
        return [ view, new LCardioDelegate(view) ];
    }
}

//! 按键委托：统一在「松开」事件响应，避免长按连发
class LCardioDelegate extends WatchUi.InputDelegate {

    private var _view;

    public function initialize(view as LCardioView) {
        InputDelegate.initialize();
        _view = view;
    }

    public function onKey(evt as KeyEvent) as Boolean {
        try {
            // 只在「松开」事件响应，避免长按连发
            if (evt.getType() != WatchUi.PRESS_TYPE_UP) { return true; }
            return _view.handleKey(evt.getKey());
        } catch (e) {
            return true;
        }
    }
}

//! 主视图
class LCardioView extends WatchUi.View {

    private var mState     as Number = ST_IDLE;
    private var mSession   as ActivityRecording.Session or Null = null;
    private var mTickTimer as Timer.Timer or Null = null;

    // 时间与能耗
    private var mAccumSec  as Float = 0.0;    // 累计运动秒数（暂停不计）
    private var mKcal      as Float = 0.0;    // 累计卡路里（估算）
    private var mTimerStr  as String = "0:00";
    private var mKcalStr   as String = "0";
    private var mAvgHrStr  as String = "--";

    // 心率（三通道共用落账）
    private var mHrStr       as String = "--";
    private var mHrSum       as Float  = 0.0;
    private var mHrCount     as Number = 0;
    private var mAvgHr       as Number = 0;
    private var mLastHrCbMs  as Number = 0;

    private var mErrStr as String = "";

    public function initialize() {
        View.initialize();
        mTickTimer = new Timer.Timer();
        try {
            mTickTimer.start(method(:onTick), 1000, true);
        } catch (e) {
            mErrStr = "TMR: " + e.getErrorMessage();
        }
    }

    //! 退出前清理：停定时器、注销传感器、（运动中）保存会话
    public function onLayout(dc as Dc) as Void { }

    //! 每秒心跳：刷新时钟/计时/心率兜底/卡路里
    public function onTick() as Void {
        try {
            if (mState == ST_RUN) {
                mAccumSec += 1.0;

                // 备用通道：传感器回调超过 3 秒没送来心率才轮询，
                // 避免同一份样本被两条通道重复计入均值
                if (System.getTimer() - mLastHrCbMs > 3000) {
                    pollActivityMonitorHr();
                    if (System.getTimer() - mLastHrCbMs > 3000) {
                        pollSensorHistoryHr();
                    }
                }

                // 卡路里（按当前心率估算；无心率时按均值估算）
                var hrNow = 0;
                if (mHrStr != "--") {
                    hrNow = mHrStr.toNumber();
                } else if (mAvgHr > 0) {
                    hrNow = mAvgHr;
                }
                if (hrNow > 30) {
                    mKcal += hrNow * KCAL_PER_HR_SEC;
                }
            }
            refreshStrings();
        } catch (e) { mErrStr = "TICK: " + e.getErrorMessage(); }
        WatchUi.requestUpdate();
    }

    //! 按键入口（只收到「松开」事件）
    public function handleKey(key as WatchUi.Key) as Boolean {
        try {
            if (mState == ST_IDLE) {
                if (WatchUi.KEY_ENTER == key) { startWorkout(); return true; }
                if (WatchUi.KEY_MENU  == key) { exitApp(); return true; }     // 长按 UP 退出
            } else if (mState == ST_RUN) {
                if (WatchUi.KEY_ENTER == key) { pauseWorkout(); return true; }
                if (WatchUi.KEY_ESC   == key) { endWorkout(false); return true; } // 结束并保存
                if (WatchUi.KEY_MENU  == key) { endWorkout(true); return true; }  // 保存并退出
            } else if (mState == ST_PAUSE) {
                if (WatchUi.KEY_ENTER == key) { resumeWorkout(); return true; }
                if (WatchUi.KEY_ESC   == key) { endWorkout(false); return true; }
                if (WatchUi.KEY_MENU  == key) { endWorkout(true); return true; }
            } else if (mState == ST_DONE) {
                if (WatchUi.KEY_ENTER == key || WatchUi.KEY_ESC == key
                    || WatchUi.KEY_MENU == key) {
                    exitApp();
                    return true;
                }
            }
        } catch (e) { mErrStr = "KEY: " + e.getErrorMessage(); }
        return true;
    }

    //! 开始：创建有氧训练会话 + 注册心率监听
    private function startWorkout() as Void {
        if (mSession != null) { return; }
        mErrStr = "";
        try {
            mSession = ActivityRecording.createSession({
                :name     => "有氧运动+",
                :sport    => Activity.SPORT_TRAINING,
                :subSport => Activity.SUB_SPORT_CARDIO_TRAINING
            });
            if (mSession != null && !mSession.start()) {
                mErrStr = "会话启动失败";
                mSession = null;
                return;
            }
        } catch (e) {
            mErrStr = "SES: " + e.getErrorMessage();
            mSession = null;
            return;
        }
        registerHrListener();
        mAccumSec = 0.0;
        mKcal = 0.0;
        mHrSum = 0.0; mHrCount = 0; mAvgHr = 0; mLastHrCbMs = 0;
        mState = ST_RUN;
        WatchUi.requestUpdate();
    }

    //! 暂停：停止 FIT 录制 + 冻结计时
    private function pauseWorkout() as Void {
        try {
            if (mSession != null && mSession.isRecording() && !mSession.stop()) {
                mErrStr = "暂停失败，继续计时";
                return;   // 停录失败则保持运动态，避免计时与记录错位
            }
        } catch (e) { mErrStr = "STP: " + e.getErrorMessage(); return; }
        mState = ST_PAUSE;
        WatchUi.requestUpdate();
    }

    //! 继续：恢复 FIT 录制 + 计时
    private function resumeWorkout() as Void {
        try {
            if (mSession != null && !mSession.isRecording() && !mSession.start()) {
                mErrStr = "恢复失败";
                return;
            }
        } catch (e) { mErrStr = "RES: " + e.getErrorMessage(); return; }
        mState = ST_RUN;
        WatchUi.requestUpdate();
    }

    //! 结束：停录制 → 存记录；askExit 为 true 时存完直接退出应用
    private function endWorkout(askExit as Boolean) as Void {
        try {
            if (mSession != null) {
                if (mSession.isRecording()) { mSession.stop(); }
                if (!mSession.save()) { mErrStr = "保存失败（记录可能未存）"; }
            }
        } catch (e) {
            mErrStr = "SAVE: " + e.getErrorMessage();
        }
        unregisterHrListener();
        mState = ST_DONE;
        mSession = null;
        if (askExit) { exitApp(); }
        WatchUi.requestUpdate();
    }

    //! 退出应用
    private function exitApp() as Void {
        try { if (mTickTimer != null) { mTickTimer.stop(); } } catch (e) { }
        unregisterHrListener();
        System.exit();
    }

    //! 注册心率传感器监听（间期必须显式启用，否则回调里 heartRateData 为 null）
    private function registerHrListener() as Void {
        try {
            Sensor.registerSensorDataListener(method(:onSensor),
                { :period => 1,
                  :heartBeatIntervals => { :enabled => true } });
        } catch (e) {
            mErrStr = "REG: " + e.getErrorMessage();
        }
    }

    private function unregisterHrListener() as Void {
        try { Sensor.unregisterSensorDataListener(); } catch (e) { }
    }

    //! 传感器回调：由心跳间期（RR interval，毫秒）换算实时心率
    public function onSensor(sensorData as Sensor.SensorData) as Void {
        try {
            var hd = sensorData.heartRateData;
            if (hd == null) { return; }
            var iv = hd.heartBeatIntervals;
            if (iv == null || iv.size() < 1) { return; }
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
        } catch (e) { mErrStr = "SEN: " + e.getErrorMessage(); }
    }

    //! 心率样本落账（三条通道共用）
    private function applyHeartRate(hr as Numeric) as Void {
        var hrN = hr.toNumber();
        mHrStr = hrN.toString();
        mHrSum += hrN * 1.0;
        mHrCount += 1;
        mAvgHr = (mHrSum / mHrCount).toNumber();
        mLastHrCbMs = System.getTimer();
    }

    //! 备用通道 2：系统心率监测（真机最可靠）
    private function pollActivityMonitorHr() as Void {
        var hr = null;
        try {
            if ((Toybox has :ActivityMonitor) && (ActivityMonitor has :getHeartRateHistory)) {
                var itr = ActivityMonitor.getHeartRateHistory(1, true);   // 最近 1 个样本，最新在前
                if (itr != null) {
                    var s = itr.next();
                    if (s != null && s.heartRate != null
                        && s.heartRate != ActivityMonitor.INVALID_HR_SAMPLE
                        && s.heartRate > 0) {
                        hr = s.heartRate;
                    }
                }
            }
        } catch (e) { return; }
        if (hr != null) { applyHeartRate(hr as Numeric); }
    }

    //! 备用通道 3：SensorHistory 心率历史
    private function pollSensorHistoryHr() as Void {
        if ((Toybox has :SensorHistory) && (SensorHistory has :getHeartRateHistory)) {
            var itr = null;
            try {
                itr = SensorHistory.getHeartRateHistory({ :period => 1, :order => SensorHistory.ORDER_NEWEST_FIRST });
            } catch (e) {
                return;
            }
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

    //! 刷新各显示字符串
    private function refreshStrings() as Void {
        // 当前时间
        var t = System.getClockTime();
        var clockStr = Lang.format("$1$:$2$", [ t.hour.format("%02d"), t.min.format("%02d") ]);
        mClockStr = clockStr;

        // 运动时间（秒 → H:MM:SS 或 M:SS）
        var el = mAccumSec.toNumber();
        if (el >= 3600) {
            mTimerStr = Lang.format("$1$:$2$:$3$", [
                (el / 3600).toNumber().toString(),
                ((el % 3600) / 60).toNumber().format("%02d"),
                (el % 60).toNumber().format("%02d")
            ]);
        } else {
            mTimerStr = Lang.format("$1$:$2$", [
                (el / 60).toNumber().toString(),
                (el % 60).toNumber().format("%02d")
            ]);
        }

        // 卡路里（估算，整数显示）
        mKcalStr = mKcal.toNumber().toString();

        // 平均心率
        if (mHrCount > 0) {
            mAvgHrStr = mAvgHr.toString();
        } else {
            mAvgHrStr = "--";
        }
    }

    private var mClockStr as String = "--:--";

    //! 平均心率 → 区间颜色（灰/蓝/绿/橙/红）
    private function zoneColor(hr as Number) as Number {
        if (hr <= 116) { return Graphics.COLOR_DK_GRAY; }
        if (hr <= 135) { return Graphics.COLOR_BLUE; }
        if (hr <= 150) { return Graphics.COLOR_GREEN; }
        if (hr <= 169) { return Graphics.COLOR_ORANGE; }
        return Graphics.COLOR_RED;
    }

    //! 绘制
    public function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();
        var cxM = (w / 2).toNumber();

        // 顶部心率区间弧（按平均心率填充）
        drawZoneArc(dc, cxM, (h / 2).toNumber(), h, mAvgHr);

        var numH  = dc.getFontHeight(Graphics.FONT_NUMBER_MEDIUM);
        var numSH = dc.getFontHeight(Graphics.FONT_NUMBER_MILD);
        var tinyH = dc.getFontHeight(Graphics.FONT_TINY);
        var gap   = 4;

        var cxL = (w * 0.32).toNumber();
        var cxR = (w * 0.68).toNumber();

        if (mState == ST_IDLE) {
            // 空闲：时钟居中大字 + 提示
            drawBold(dc, cxM, (h * 0.34).toNumber(), mClockStr);
            drawHint(dc, cxM, (h * 0.60).toNumber(), "START 开始运动");
            drawHint(dc, cxM, (h * 0.72).toNumber(),
                mErrStr != "" ? mErrStr : "长按 UP 退出");
            return;
        }

        if (mState == ST_DONE) {
            drawBold(dc, cxM, (h * 0.30).toNumber(), mTimerStr);
            drawHint(dc, cxM, (h * 0.50).toNumber(), "平均心率 " + mAvgHrStr);
            drawHint(dc, cxM, (h * 0.60).toNumber(), "卡路里 " + mKcalStr);
            drawHint(dc, cxM, (h * 0.72).toNumber(),
                mErrStr != "" ? mErrStr : "按任意键退出");
            return;
        }

        // ---- RUN / PAUSE：三行布局（行3 贴行2 数值底部动态排布，防串行防出圈）----
        var r1 = numH;
        var total = r1 + gap + (tinyH + gap + numSH) + (8 + tinyH + gap + numSH);
        var y = ((h - total) / 2).toNumber();

        // 行1：心率（左） | 当前时间（右）
        drawBold(dc, cxL, y, mHrStr);
        drawBold(dc, cxR, y, mClockStr);
        y += r1 + gap;

        // 行2：运动时间 | 卡路里
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cxL, y, Graphics.FONT_TINY, "运动时间", Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(cxR, y, Graphics.FONT_TINY, "卡路里", Graphics.TEXT_JUSTIFY_CENTER);

        var v2y = (y + tinyH + gap).toNumber();
        drawBoldSmall(dc, cxL, v2y, mTimerStr);
        drawBoldSmall(dc, cxR, v2y, mKcalStr);

        // 行3：平均心率（居中）
        var y3 = (v2y + numSH + 8).toNumber();
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cxM, y3, Graphics.FONT_TINY, "平均心率", Graphics.TEXT_JUSTIFY_CENTER);

        drawBoldSmall(dc, cxM, (y3 + tinyH + gap).toNumber(), mAvgHrStr);

        // 暂停状态角标 + 错误提示
        if (mState == ST_PAUSE) {
            drawHint(dc, cxM, (h * 0.88).toNumber(), "已暂停 START 继续");
        } else if (mErrStr != "") {
            drawHint(dc, cxM, (h * 0.88).toNumber(), mErrStr);
        }
    }

    //! 提示文字（小号）
    private function drawHint(dc as Dc, x as Number, y as Number, text as String) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, Graphics.FONT_TINY, text, Graphics.TEXT_JUSTIFY_CENTER);
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

    //! 小号数值文字加重加粗
    private function drawBoldSmall(dc as Dc, x as Number, y as Number, text as String) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        for (var dx = 0; dx < 3; dx++) {
            for (var dy = 0; dy < 2; dy++) {
                dc.drawText(x + dx, y + dy, Graphics.FONT_NUMBER_MILD, text, Graphics.TEXT_JUSTIFY_CENTER);
            }
        }
    }

    //! 顶部心率刻度弧：15 段，自左向右「细 → 粗」，颜色按 灰→蓝→绿→橙→红 递进
    private function drawZoneArc(dc as Dc, cx as Number, cy as Number, h as Number, avgHr as Number) as Void {
        if (avgHr <= 0) { return; }

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
            if (hrSeg > avgHr) { continue; }

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
}
