Attribute VB_Name = "ExcelGoalTracker"
Option Explicit

' Beginner-friendly Excel goal tracker with on-sheet buttons.
Private Const GOAL_SHEET_NAME As String = "目标树"
Private Const SUMMARY_SHEET_NAME As String = "目标汇总"
Private Const HEADER_ROW As Long = 5
Private Const FIRST_DATA_ROW As Long = 6

' Run once from the VBA editor. It creates the worksheet, columns, dropdowns, and buttons.
Public Sub SetupGoalTracker()
    Dim ws As Worksheet
    Dim answer As VbMsgBoxResult

    On Error Resume Next
    Set ws = ThisWorkbook.Worksheets(GOAL_SHEET_NAME)
    On Error GoTo 0

    If Not ws Is Nothing Then
        If Application.WorksheetFunction.CountA(ws.Rows(FIRST_DATA_ROW & ":" & ws.Rows.Count)) > 0 Then
            answer = MsgBox("目标树中已有数据。重新初始化会删除这些数据。" & vbCrLf & _
                            "建议先备份。确定要清空并重建吗？", vbYesNo + vbExclamation, "请确认")
            If answer <> vbYes Then Exit Sub
        End If
        Application.DisplayAlerts = False
        ws.Delete
        Application.DisplayAlerts = True
    End If

    Set ws = ThisWorkbook.Worksheets.Add(After:=ThisWorkbook.Worksheets(ThisWorkbook.Worksheets.Count))
    ws.Name = GOAL_SHEET_NAME
    BuildGoalSheet ws

    MsgBox "准备好了！请使用表格上方的按钮添加任务、更新进度或生成汇总。", vbInformation, "目标跟踪模板"
End Sub

Private Sub BuildGoalSheet(ByVal ws As Worksheet)
    Dim headers As Variant
    Dim i As Long

    With ws
        .Cells.Clear
        .Range("A1:N1").Merge
        .Range("A1").Value = "工作目标树与任务跟踪"
        .Range("A1").Font.Bold = True
        .Range("A1").Font.Size = 18
        .Range("A1").HorizontalAlignment = xlCenter
        .Range("A1").Interior.Color = RGB(217, 225, 242)
        .Rows(1).RowHeight = 32
        .Range("A2").Value = "使用提示：点击下面按钮操作；每周更新反馈和进度。目标层级建议：1总目标、2阶段目标、3举措、4任务。"
        .Range("A2:N2").Merge
        .Range("A2").WrapText = True
        .Rows(2).RowHeight = 30

        AddActionButton ws, "btnAdd", "＋ 新增目标/任务", "AddGoalTask", 10, 58
        AddActionButton ws, "btnUpdate", "更新所选行", "UpdateSelectedTask", 150, 58
        AddActionButton ws, "btnRefresh", "刷新颜色", "RefreshGoalColors", 290, 58
        AddActionButton ws, "btnSummary", "生成汇总", "BuildGoalSummary", 430, 58

        headers = Array("目标ID", "上级目标ID", "层级", "类型", "目标/任务内容", "衡量标准", _
                        "负责人", "开始日期", "截止日期", "进度%", "状态", "最新反馈", "下一步举措", "实际结果")
        For i = LBound(headers) To UBound(headers)
            .Cells(HEADER_ROW, i + 1).Value = headers(i)
        Next i

        With .Range(.Cells(HEADER_ROW, 1), .Cells(HEADER_ROW, 14))
            .Font.Bold = True
            .Interior.Color = RGB(68, 114, 196)
            .Font.Color = RGB(255, 255, 255)
            .WrapText = True
            .HorizontalAlignment = xlCenter
        End With
        .Rows(HEADER_ROW).RowHeight = 32
        .Columns("A:D").ColumnWidth = 14
        .Columns("E").ColumnWidth = 30
        .Columns("F").ColumnWidth = 24
        .Columns("G").ColumnWidth = 14
        .Columns("H:I").ColumnWidth = 14
        .Columns("J:K").ColumnWidth = 12
        .Columns("L:N").ColumnWidth = 28
        .Range("H" & FIRST_DATA_ROW & ":I1000").NumberFormat = "yyyy-mm-dd"
        .Range("J" & FIRST_DATA_ROW & ":J1000").NumberFormat = "0%"
        .Range("J" & FIRST_DATA_ROW & ":J1000").Validation.Delete
        .Range("J" & FIRST_DATA_ROW & ":J1000").Validation.Add Type:=xlValidateDecimal, _
            AlertStyle:=xlValidAlertStop, Operator:=xlBetween, Formula1:="0", Formula2:="1"
        .Range("K" & FIRST_DATA_ROW & ":K1000").Validation.Delete
        .Range("K" & FIRST_DATA_ROW & ":K1000").Validation.Add Type:=xlValidateList, _
            AlertStyle:=xlValidAlertStop, Formula1:="未开始,进行中,已完成,延期,暂停"
        .Range(.Cells(HEADER_ROW, 1), .Cells(1000, 14)).Borders.LineStyle = xlContinuous
        .Range(.Cells(HEADER_ROW, 1), .Cells(HEADER_ROW, 14)).AutoFilter
    End With
End Sub

Private Sub AddActionButton(ByVal ws As Worksheet, ByVal shapeName As String, ByVal caption As String, _
                            ByVal macroName As String, ByVal leftPos As Double, ByVal topPos As Double)
    Dim btn As Shape
    Set btn = ws.Shapes.AddShape(msoShapeRoundedRectangle, leftPos, topPos, 125, 30)
    With btn
        .Name = shapeName
        .TextFrame.Characters.Text = caption
        .TextFrame.Characters.Font.Bold = True
        .OnAction = "'" & ThisWorkbook.Name & "'!" & macroName
        .Fill.ForeColor.RGB = RGB(91, 155, 213)
        .Line.ForeColor.RGB = RGB(68, 114, 196)
    End With
End Sub

' The button opens simple prompts and adds a row. IDs are generated automatically.
Public Sub AddGoalTask()
    Dim ws As Worksheet
    Dim r As Long
    Dim levelText As String
    Dim progressText As String
    Dim statusText As String
    Dim d As String

    Set ws = GetGoalSheet()
    If ws Is Nothing Then Exit Sub
    r = ws.Cells(ws.Rows.Count, "A").End(xlUp).Row + 1
    If r < FIRST_DATA_ROW Then r = FIRST_DATA_ROW

    ws.Cells(r, 1).Value = NextGoalID(ws)
    ws.Cells(r, 2).Value = AskText("上级目标ID（总目标可留空）")
    levelText = AskText("层级：1=总目标，2=阶段目标，3=举措，4=任务", "4")
    If levelText = "" Then Exit Sub
    ws.Cells(r, 3).Value = levelText
    ws.Cells(r, 4).Value = AskText("类型（总目标/阶段目标/举措/任务）", "任务")
    ws.Cells(r, 5).Value = AskText("目标或任务内容（必填）")
    If CStr(ws.Cells(r, 5).Value) = "" Then
        ws.Rows(r).ClearContents
        MsgBox "内容不能为空，已取消新增。", vbExclamation
        Exit Sub
    End If
    ws.Cells(r, 6).Value = AskText("衡量标准（做到什么算完成？）")
    ws.Cells(r, 7).Value = AskText("负责人")
    d = AskText("开始日期（例如 2026-11-17，可留空）")
    If d <> "" And IsDate(d) Then ws.Cells(r, 8).Value = CDate(d)
    d = AskText("截止日期（例如 2026-12-31，可留空）")
    If d <> "" And IsDate(d) Then ws.Cells(r, 9).Value = CDate(d)

    progressText = AskText("当前进度（输入 0 到 100，例如 40）", "0")
    If IsNumeric(progressText) Then
        If Val(progressText) >= 0 And Val(progressText) <= 100 Then ws.Cells(r, 10).Value = Val(progressText) / 100
    End If
    statusText = AskText("状态：未开始/进行中/已完成/延期/暂停", "未开始")
    If statusText = "" Then statusText = "未开始"
    ws.Cells(r, 11).Value = statusText
    ws.Cells(r, 12).Value = AskText("最新反馈（可留空）")
    ws.Cells(r, 13).Value = AskText("下一步举措（可留空）")
    ws.Cells(r, 14).Value = AskText("实际结果（未完成可留空）")
    RefreshGoalColors
    MsgBox "已添加记录 " & ws.Cells(r, 1).Value, vbInformation
End Sub

' Select any cell in a task row, then click this button to update progress and feedback.
Public Sub UpdateSelectedTask()
    Dim ws As Worksheet
    Dim r As Long
    Dim answer As Variant

    Set ws = GetGoalSheet()
    If ws Is Nothing Then Exit Sub
    If ActiveSheet.Name <> ws.Name Or ActiveCell.Row < FIRST_DATA_ROW Then
        MsgBox "请先在“目标树”中点击要更新的任务所在行，再点“更新所选行”。", vbExclamation
        Exit Sub
    End If
    r = ActiveCell.Row

    answer = Application.InputBox("进度百分比（0 到 100）", "更新进度", ws.Cells(r, 10).Value * 100, Type:=1)
    If VarType(answer) = vbBoolean And answer = False Then Exit Sub
    If answer < 0 Or answer > 100 Then
        MsgBox "进度必须是 0 到 100 之间的数字。", vbExclamation
        Exit Sub
    End If
    ws.Cells(r, 10).Value = CDbl(answer) / 100
    ws.Cells(r, 11).Value = AskText("状态：未开始/进行中/已完成/延期/暂停", CStr(ws.Cells(r, 11).Value))
    ws.Cells(r, 12).Value = AskText("最新反馈", CStr(ws.Cells(r, 12).Value))
    ws.Cells(r, 13).Value = AskText("下一步举措", CStr(ws.Cells(r, 13).Value))
    If CStr(ws.Cells(r, 11).Value) = "已完成" Then
        ws.Cells(r, 14).Value = AskText("实际结果", CStr(ws.Cells(r, 14).Value))
    End If
    RefreshGoalColors
    MsgBox "所选记录已更新。", vbInformation
End Sub

Public Sub RefreshGoalColors()
    Dim ws As Worksheet
    Dim lastRow As Long
    Dim r As Long
    Dim status As String

    Set ws = GetGoalSheet()
    If ws Is Nothing Then Exit Sub
    lastRow = ws.Cells(ws.Rows.Count, "A").End(xlUp).Row
    For r = FIRST_DATA_ROW To lastRow
        status = Trim$(CStr(ws.Cells(r, 11).Value))
        Select Case status
            Case "已完成": ws.Range(ws.Cells(r, 1), ws.Cells(r, 14)).Interior.Color = RGB(198, 239, 206)
            Case "进行中": ws.Range(ws.Cells(r, 1), ws.Cells(r, 14)).Interior.Color = RGB(255, 242, 204)
            Case "延期": ws.Range(ws.Cells(r, 1), ws.Cells(r, 14)).Interior.Color = RGB(248, 203, 203)
            Case "暂停": ws.Range(ws.Cells(r, 1), ws.Cells(r, 14)).Interior.Color = RGB(217, 217, 217)
            Case Else: ws.Range(ws.Cells(r, 1), ws.Cells(r, 14)).Interior.ColorIndex = xlColorIndexNone
        End Select
    Next r
End Sub

Public Sub BuildGoalSummary()
    Dim sourceWs As Worksheet
    Dim ws As Worksheet
    Dim lastRow As Long
    Dim dataRange As Range

    Set sourceWs = GetGoalSheet()
    If sourceWs Is Nothing Then Exit Sub
    On Error Resume Next
    Set ws = ThisWorkbook.Worksheets(SUMMARY_SHEET_NAME)
    On Error GoTo 0
    If ws Is Nothing Then
        Set ws = ThisWorkbook.Worksheets.Add(After:=ThisWorkbook.Worksheets(ThisWorkbook.Worksheets.Count))
        ws.Name = SUMMARY_SHEET_NAME
    End If

    lastRow = sourceWs.Cells(sourceWs.Rows.Count, "A").End(xlUp).Row
    ws.Cells.Clear
    ws.Range("A1:B1").Value = Array("指标", "结果")
    ws.Range("A1:B1").Font.Bold = True
    ws.Range("A1:B1").Interior.Color = RGB(217, 225, 242)
    ws.Range("A2").Value = "目标/任务总数"
    ws.Range("B2").Value = Application.Max(0, lastRow - HEADER_ROW)
    ws.Range("A3").Value = "已完成"
    ws.Range("B3").Value = Application.CountIf(sourceWs.Range("K" & FIRST_DATA_ROW & ":K" & lastRow), "已完成")
    ws.Range("A4").Value = "进行中"
    ws.Range("B4").Value = Application.CountIf(sourceWs.Range("K" & FIRST_DATA_ROW & ":K" & lastRow), "进行中")
    ws.Range("A5").Value = "延期"
    ws.Range("B5").Value = Application.CountIf(sourceWs.Range("K" & FIRST_DATA_ROW & ":K" & lastRow), "延期")
    ws.Range("A6").Value = "平均进度"
    If lastRow >= FIRST_DATA_ROW Then
        Set dataRange = sourceWs.Range("J" & FIRST_DATA_ROW & ":J" & lastRow)
        If Application.Count(dataRange) > 0 Then ws.Range("B6").Value = Application.Average(dataRange)
    End If
    ws.Range("B6").NumberFormat = "0%"
    ws.Columns("A:B").AutoFit
    MsgBox "汇总表已生成/更新。", vbInformation
End Sub

Private Function GetGoalSheet() As Worksheet
    On Error Resume Next
    Set GetGoalSheet = ThisWorkbook.Worksheets(GOAL_SHEET_NAME)
    On Error GoTo 0
    If GetGoalSheet Is Nothing Then
        MsgBox "还没有目标树工作表。请先运行 SetupGoalTracker。", vbExclamation
    End If
End Function

Private Function AskText(ByVal prompt As String, Optional ByVal defaultValue As String = "") As String
    Dim result As Variant
    result = Application.InputBox(prompt, "目标跟踪", defaultValue, Type:=2)
    If VarType(result) = vbBoolean And result = False Then
        AskText = ""
    Else
        AskText = Trim$(CStr(result))
    End If
End Function

Private Function NextGoalID(ByVal ws As Worksheet) As String
    Dim lastRow As Long
    Dim r As Long
    Dim n As Long
    Dim currentId As String

    lastRow = ws.Cells(ws.Rows.Count, "A").End(xlUp).Row
    For r = FIRST_DATA_ROW To lastRow
        currentId = CStr(ws.Cells(r, 1).Value)
        If UCase$(Left$(currentId, 1)) = "G" And IsNumeric(Mid$(currentId, 2)) Then
            If CLng(Mid$(currentId, 2)) > n Then n = CLng(Mid$(currentId, 2))
        End If
    Next r
    NextGoalID = "G" & Format$(n + 1, "000")
End Function
