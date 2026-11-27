on verifyWorkbook(directory, fileName, expectedRows)
    set filePath to directory & "/" & fileName
    set expectedLabels to {{"=2+3"}, {"+标签"}, {"-标签"}, {"@标签"}, {(character id 9) & "标签"}, {(character id 13) & "标签"}}
    tell application id "com.microsoft.Excel"
        with timeout of 15 seconds
            if exists workbook fileName then error "Close the existing workbook named " & fileName
            do shell script "/usr/bin/open -b com.microsoft.Excel " & quoted form of filePath
            repeat 30 times
                if exists workbook fileName then exit repeat
                delay 0.2
            end repeat
            if not (exists workbook fileName) then error "Excel did not open " & fileName
            set checkedWorkbook to workbook fileName
            try
                if (count worksheets of checkedWorkbook) is not 1 then error "Unexpected worksheet count"
                set checkedSheet to worksheet "库存盘点" of checkedWorkbook
                if (value of range "A1:D1" of checkedSheet) is not {{"货架", "商品标签", "盘点数量", "单位"}} then error "Unexpected headers"
                if (count rows of used range of checkedSheet) is not (expectedRows + 1) then error "Unexpected data row count"
                if (count columns of used range of checkedSheet) is not 4 then error "Unexpected column count"
                set links to link sources checkedWorkbook
                if links is not missing value and links is not {} and links is not "" then error "Workbook carries external links"
                if expectedRows > 0 then
                    if (get value of range "B2:B7" of checkedSheet) is not expectedLabels then error "Labels changed"
                    repeat with rowIndex from 2 to (expectedRows + 1)
                        set cellAddress to "B" & rowIndex
                        if (get has formula of range cellAddress of checkedSheet) is not false then error "Formula found at " & cellAddress
                        set quantityCell to range ("C" & rowIndex) of checkedSheet
                        if (value of quantityCell) is not 12.5 then error "Quantity changed"
                        if (number format of quantityCell) is not "0.00" then error "Number format changed"
                    end repeat
                end if
                set oldSlot to value of range "B19" of checkedSheet
                if oldSlot is not missing value and oldSlot is not "" then error "Stale value remains"
            on error errorMessage number errorNumber
                close checkedWorkbook saving no
                error errorMessage number errorNumber
            end try
            close checkedWorkbook saving no
            set installedVersion to get version
            return installedVersion & " PASS " & fileName & " (" & expectedRows & " data rows)"
        end timeout
    end tell
end verifyWorkbook

on run arguments
    if (count arguments) is not 1 then error "Usage: osascript verify_in_excel.applescript /absolute/path/to/fixtures"
    set fixtureDirectory to item 1 of arguments
    set emptyReport to verifyWorkbook(fixtureDirectory, "inventory-headers-only.xlsx", 0)
    set filledReport to verifyWorkbook(fixtureDirectory, "inventory-some-rows.xlsx", 6)
    return emptyReport & linefeed & filledReport
end run
