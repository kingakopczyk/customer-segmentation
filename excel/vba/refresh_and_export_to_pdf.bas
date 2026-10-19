Attribute VB_Name = "Module1"
Option Explicit

Sub RefreshDashboards()
    ' Refreshes PivotTables and recalculates all formulas
    ThisWorkbook.RefreshAll
    Application.CalculateFull
End Sub

Sub ExportDashboardsToPDF()
    Dim sheetName As Variant
    Dim folderPath As String
    folderPath = ThisWorkbook.Path & Application.PathSeparator

    For Each sheetName In Array("courses_dashboard", "categories_mini_dashboard")
        With ThisWorkbook.Worksheets(sheetName).PageSetup
            .Orientation = xlLandscape
            .Zoom = False
            .FitToPagesWide = 1
            .FitToPagesTall = 1
        End With

        ThisWorkbook.Worksheets(sheetName).ExportAsFixedFormat _
            Type:=xlTypePDF, _
            Filename:=folderPath & sheetName & "_" & Format(Date, "yyyy-mm-dd") & ".pdf", _
            Quality:=xlQualityStandard, _
            OpenAfterPublish:=False
    Next sheetName

    MsgBox "PDFs saved in folder: " & folderPath, vbInformation
End Sub

Sub RefreshAndExport()
    RefreshDashboards
    ExportDashboardsToPDF
End Sub

