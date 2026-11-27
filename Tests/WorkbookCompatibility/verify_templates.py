"""Generate and check fixed, non-biological XLSX compatibility samples."""

import argparse
from copy import copy
from pathlib import Path
from xml.etree import ElementTree
from zipfile import ZipFile

from openpyxl import Workbook, load_workbook
from openpyxl.comments import Comment
from openpyxl.packaging.relationship import Relationship
from openpyxl.styles import Alignment, Border, Font, NamedStyle, PatternFill, Side
from openpyxl.workbook.external_link.external import ExternalBook, ExternalLink

SHEET = "库存盘点"
HEADERS = ("货架", "商品标签", "盘点数量", "单位")
LABELS = ("=2+3", "+标签", "-标签", "@标签", "\t标签", "\r标签")
ROWS = tuple(("B-04", label, 12.5, "箱") for label in LABELS)
CASES = {"headers-only": (), "some-rows": ROWS}
OLD_VALUE = "旧库存记录"
OLD_COMMENT = "旧盘点批注"
OLD_ROW = 19
EXTERNAL_LINK = "file:///missing-template-source.xlsx"
SHEET_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"


def new_inventory():
    workbook = Workbook()
    sheet = workbook.active
    sheet.title = SHEET
    sheet.append(HEADERS)
    for cell in sheet[1]:
        cell.font = Font(bold=True, color="FFFFFF")
        cell.fill = PatternFill("solid", fgColor="193B57")
    sheet.freeze_panes = "A2"
    sheet.column_dimensions["B"].width = 24
    workbook.add_named_style(NamedStyle(
        name="Inventory quantity",
        number_format="0.00",
        font=Font(color="193B57"),
        fill=PatternFill("solid", fgColor="EEF4F8"),
        alignment=Alignment(horizontal="right"),
        border=Border(bottom=Side(style="thin", color="AEC4D2")),
    ))
    return workbook


def make_fixtures(directory):
    source = new_inventory()
    sheet = source.active
    sheet["C2"].style = "Inventory quantity"
    sheet[f"B{OLD_ROW}"] = OLD_VALUE
    sheet[f"B{OLD_ROW}"].comment = Comment(OLD_COMMENT, "Fixture")
    link = ExternalLink(externalBook=ExternalBook(id="rId1"))
    link.file_link = Relationship(type="externalLinkPath", Target=EXTERNAL_LINK, TargetMode="External")
    source._external_links.append(link)
    source.save(directory / "inventory-template.xlsx")

    for name, records in CASES.items():
        workbook = new_inventory()
        sheet = workbook.active
        for record in records:
            sheet.append(record)
            row = sheet.max_row
            sheet[f"B{row}"].data_type = "s"
            sheet[f"C{row}"].style = "Inventory quantity"
        workbook.save(directory / f"inventory-{name}.xlsx")


def check_package(path, *, source):
    with ZipFile(path) as package:
        assert package.testzip() is None, path
        names = package.namelist()
        assert len(names) == len(set(names)), path
        if source:
            assert any(name.startswith("xl/comments/") for name in names), path
            assert "xl/externalLinks/externalLink1.xml" in names, path
            relationships = package.read("xl/externalLinks/_rels/externalLink1.xml.rels")
            assert EXTERNAL_LINK.encode() in relationships, path
            return

        assert not any(name.startswith(("xl/comments/", "xl/externalLinks/")) for name in names), path
        for name in names:
            if name.endswith(".rels"):
                relations = ElementTree.fromstring(package.read(name))
                assert all(rel.get("TargetMode") != "External" for rel in relations), (path, name)
        sheet = ElementTree.fromstring(package.read("xl/worksheets/sheet1.xml"))
        assert sheet.find(f".//{{{SHEET_NS}}}f") is None, path
        workbook = ElementTree.fromstring(package.read("xl/workbook.xml"))
        assert workbook.find(f".//{{{SHEET_NS}}}externalReferences") is None, path
        for name in names:
            if name.endswith(".xml"):
                contents = ElementTree.fromstring(package.read(name))
                assert OLD_VALUE not in contents.itertext(), (path, name)


def check_workbooks(directory):
    path = directory / "inventory-template.xlsx"
    check_package(path, source=True)
    source = load_workbook(path)
    template = source[SHEET]
    assert template[f"B{OLD_ROW}"].value == OLD_VALUE
    assert template[f"B{OLD_ROW}"].comment.text == OLD_COMMENT

    for name, records in CASES.items():
        path = directory / f"inventory-{name}.xlsx"
        check_package(path, source=False)
        workbook = load_workbook(path)
        assert workbook.sheetnames == [SHEET], path
        sheet = workbook[SHEET]
        assert list(sheet.values) == [HEADERS, *records], path
        assert sheet.freeze_panes == template.freeze_panes, path
        assert sheet.column_dimensions["B"].width == template.column_dimensions["B"].width, path
        for cell, original in zip(sheet[1], template[1], strict=True):
            assert cell.font == copy(original.font), (path, cell.coordinate)
            assert cell.fill == copy(original.fill), (path, cell.coordinate)
        for row in range(2, len(records) + 2):
            label, quantity = sheet[f"B{row}"], sheet[f"C{row}"]
            assert label.data_type == "s", (path, label.coordinate)
            assert quantity.number_format == template["C2"].number_format, (path, quantity.coordinate)
            for attr in ("font", "fill", "border", "alignment"):
                assert getattr(quantity, attr) == copy(getattr(template["C2"], attr)), (path, attr)
        assert all(cell.comment is None for row in sheet for cell in row), path
        print(f"PASS {path.name}: {len(records)} data rows")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output_directory", type=Path)
    directory = parser.parse_args().output_directory
    directory.mkdir(exist_ok=True)
    if any(directory.iterdir()):
        parser.error("output directory must be empty")
    make_fixtures(directory)
    check_workbooks(directory)


if __name__ == "__main__":
    main()
