import Toybox.Application;
import Toybox.Activity;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.WatchUi;

//! L跑步 —— 跑步数据字段 v1.3.0
//! 仿原生跑步数据屏布局：顶部心率区间弧柱 / 心率 | 当前时间 / 距离 | 计时器 / 配速
//! 白底黑字加粗；顶部弧柱按平均心率着色（灰/蓝/绿/橙/红）
class LRunTimeApp extends Application.AppBase {

    public function initialize() {
        AppBase.initialize();
    }

    //! 返回数据字段视图
    public function getInitialView() as [Views] or [Views, InputDelegates] {
        return [ new LRunTimeView() ];
    }
}

//! 数据字段视图
class LRunTimeView extends WatchUi.DataField {

    private var mTimeStr  as String = "--:--";
    private var mHrStr    as String = "--";
    private var mDistStr  as String = "0.00";
    private var mTimerStr as String = "0:00";
    private var mPaceStr  as String = "--'--\"";

    //! 当前平均心率（0 = 尚无数据，不绘制刻度弧）
    private var mAvgHr as Number = 0;

    //! 自己累计的心率均值（设备不提供 averageHeartRate 时的兜底）
    private var mHrSum   as Float  = 0.0;
    private var mHrCount as Number = 0;

    public function initialize() {
        DataField.initialize();
    }

    //! 每次数据更新时调用（约每秒一次）
    public function compute(info as Activity.Info) as Void {
        // 当前时间
        var t = System.getClockTime();
        mTimeStr = Lang.format("$1$:$2$", [ t.hour.format("%02d"), t.min.format("%02d") ]);

        if (info != null) {
            // 心率
            var hr = info.currentHeartRate;
            if (hr != null && hr > 0) {
                mHrStr = hr.toNumber().toString();
                mHrSum += hr;
                mHrCount += 1;
            } else {
                mHrStr = "--";
            }

            // 平均心率（优先用设备提供的，否则用自己累计的）
            var avgHr = null;
            if (info has :averageHeartRate) {
                avgHr = info.averageHeartRate;
            }
            if (avgHr == null || avgHr <= 0) {
                if (mHrCount > 0) {
                    avgHr = (mHrSum / mHrCount).toNumber();
                }
            }
            if (avgHr != null && avgHr > 0) {
                mAvgHr = avgHr.toNumber();
            }

            // 距离（米 → 公里，两位小数；%.2f 须用数值 format 方法，Lang.format 不认）
            if (info has :distance) {
                var dist = info.distance;
                if (dist != null) {
                    mDistStr = ((dist as Float) / 1000.0).format("%.2f");
                }
            }

            // 计时器（秒 → H:MM:SS 或 M:SS）
            var el = info.elapsedTime;
            if (el != null) {
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
            }

            // 配速（速度 m/s → 每公里分'秒）
            var spd = null;
            if (info has :speed) {
                spd = info.speed as Float;
            }
            if (spd != null && spd > 0.1) {
                var spk = (1000.0 / spd).toNumber();
                mPaceStr = Lang.format("$1$'$2$\"", [
                    (spk / 60).toNumber().toString(),
                    (spk % 60).toNumber().format("%02d")
                ]);
            } else {
                mPaceStr = "--'--\"";
            }
        }

        WatchUi.requestUpdate();
    }

    //! 平均心率 → 区间颜色
    //! ≤116 灰 / 117-135 蓝 / 136-150 绿 / 151-169 橙 / ≥170 红
    private function zoneColor(hr as Number) as Number {
        if (hr <= 116) { return Graphics.COLOR_DK_GRAY; }
        if (hr <= 135) { return Graphics.COLOR_BLUE; }
        if (hr <= 150) { return Graphics.COLOR_GREEN; }
        if (hr <= 169) { return Graphics.COLOR_ORANGE; }
        return Graphics.COLOR_RED;
    }

    //! 绘制界面（顶部弧柱 + 仿原生三行布局，白底黑字加粗）
    public function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();
        var cxM = (w / 2).toNumber();
        var cyM = (h / 2).toNumber();

        // ---- 顶部沿屏幕弧度的心率刻度条（按平均心率进度填充）----
        drawZoneArc(dc, cxM, cyM, h, mAvgHr);

        // ---- 内容三行 ----
        // 行3 位置按行2 数值的实际底部动态排布（+8px 间隙），根治串行；字号全部不动
        var numH  = dc.getFontHeight(Graphics.FONT_NUMBER_MEDIUM);
        var numSH = dc.getFontHeight(Graphics.FONT_NUMBER_MILD);
        var tinyH = dc.getFontHeight(Graphics.FONT_TINY);
        var gap   = 4;

        var r1 = numH;                  // 行1：心率 | 当前时间
        var total = r1 + gap + (tinyH + gap + numSH) + (8 + tinyH + gap + numSH);
        var y = ((h - total) / 2).toNumber();

        var cxL = (w * 0.32).toNumber();
        var cxR = (w * 0.72).toNumber();

        // 行1：心率（左，直接显示数值，无图标） | 当前时间（右）
        drawBold(dc, cxL, y, mHrStr);
        drawBold(dc, cxR, y, mTimeStr);
        y += r1 + gap;

        // 行2：距离（左） | 计时器（右），小号数字
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cxL, y, Graphics.FONT_TINY, "距离", Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(cxR, y, Graphics.FONT_TINY, "计时器", Graphics.TEXT_JUSTIFY_CENTER);

        var v2y = (y + tinyH + gap).toNumber();
        drawBoldSmall(dc, cxL, v2y, mDistStr);
        drawBoldSmall(dc, cxR, v2y, mTimerStr);

        // 行3：配速（居中，贴着行2 数值底部 + 8px，动态排布不串行；小号数字防出圈）
        var y3 = (v2y + numSH + 8).toNumber();
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cxM, y3, Graphics.FONT_TINY, "配速", Graphics.TEXT_JUSTIFY_CENTER);

        drawBoldSmall(dc, cxM, (y3 + tinyH + gap).toNumber(), mPaceStr);
    }

    //! 数值文字加重加粗：横向 3 遍 + 纵向 2 遍叠印（Garmin 点阵字无粗体，只能靠偏移叠印）
    private function drawBold(dc as Dc, x as Number, y as Number, text as String) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        for (var dx = 0; dx < 3; dx++) {
            for (var dy = 0; dy < 2; dy++) {
                dc.drawText(x + dx, y + dy, Graphics.FONT_NUMBER_MEDIUM, text, Graphics.TEXT_JUSTIFY_CENTER);
            }
        }
    }

    //! 小号数值文字加重加粗（行2防挤占、底部行防出圈用）
    private function drawBoldSmall(dc as Dc, x as Number, y as Number, text as String) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        for (var dx = 0; dx < 3; dx++) {
            for (var dy = 0; dy < 2; dy++) {
                dc.drawText(x + dx, y + dy, Graphics.FONT_NUMBER_MILD, text, Graphics.TEXT_JUSTIFY_CENTER);
            }
        }
    }

    //! 顶部心率刻度弧：15 段，自左向右「细 → 粗」，颜色按 灰→蓝→绿→橙→红 递进；
    //! 只绘制到平均心率所在区间，其余留空（不填满整条弧）
    private function drawZoneArc(dc as Dc, cx as Number, cy as Number, h as Number, avgHr as Number) as Void {
        if (avgHr <= 0) { return; }

        var n = 15;
        var aStart = -152.0;   // 起始角（度，-90 为正上方）
        var aEnd   = -28.0;    // 结束角
        var step   = (aEnd - aStart) / n;
        var segAng = step * 0.72;   // 每段实际绘制角度，段间留缺口

        var rOutBase = h * 0.470;          // 外沿贴屏幕边缘
        var tMin     = h * 0.012;          // 最细
        var tMax     = h * 0.040;          // 最粗
        var hrMin    = 90.0;               // 弧起点对应心率
        var hrMax    = 200.0;              // 弧终点对应心率

        for (var i = 0; i < n; i++) {
            // 该段代表的心率值
            var hrSeg = (hrMin + (hrMax - hrMin) * i / (n - 1)).toNumber();
            if (hrSeg > avgHr) { continue; }      // 超过当前平均心率 → 不画

            // 粗细：从左到右由细到粗
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
