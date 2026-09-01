from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.pdfgen import canvas
from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "output" / "pdf" / "driver_test_pack"

DRIVER = {
    "Full name": "Mpho Test Mdluli",
    "Test ID number": "TEST-900101-0000-000",
    "Residential address": "24 Demo Avenue, Midrand, Gauteng, 1685",
    "Vehicle": "2022 Toyota Corolla Quest 1.8",
    "Colour": "Midnight Blue",
    "Number plate": "TEST GP 123",
}

DOCUMENTS = [
    ("01_driver_licence_TEST_ONLY.pdf", "Driver Licence", [
        ("Licence number", "TEST-DL-2026-001"),
        ("Licence code", "Code B"),
        ("Test expiry", "31 December 2030"),
    ]),
    ("02_professional_driving_permit_TEST_ONLY.pdf", "Professional Driving Permit", [
        ("Permit number", "TEST-PRDP-2026-001"),
        ("Category", "Passengers"),
        ("Test expiry", "31 December 2028"),
    ]),
    ("03_vehicle_registration_TEST_ONLY.pdf", "Vehicle Registration", [
        ("VIN", "TESTVIN00000000001"),
        ("Engine number", "TEST-ENG-1800-01"),
        ("Registered owner", DRIVER["Full name"]),
    ]),
    ("04_roadworthy_certificate_TEST_ONLY.pdf", "Roadworthy Certificate", [
        ("Certificate number", "TEST-RWC-2026-001"),
        ("Inspection result", "TEST PASS"),
        ("Test expiry", "31 December 2027"),
    ]),
    ("05_vehicle_insurance_TEST_ONLY.pdf", "Vehicle Insurance", [
        ("Policy number", "TEST-POL-2026-001"),
        ("Cover", "Comprehensive - test record"),
        ("Test expiry", "31 December 2027"),
    ]),
    ("06_proof_of_address_TEST_ONLY.pdf", "Proof of Address", [
        ("Account holder", DRIVER["Full name"]),
        ("Service address", DRIVER["Residential address"]),
        ("Statement date", "15 August 2026"),
    ]),
    ("07_identity_document_TEST_ONLY.pdf", "Identity Document", [
        ("Name", DRIVER["Full name"]),
        ("Test ID number", DRIVER["Test ID number"]),
        ("Nationality", "South African - test record"),
    ]),
]


def watermark(canvas_obj: canvas.Canvas, doc):
    canvas_obj.saveState()
    canvas_obj.setFillColor(colors.Color(1, 0.25, 0.22, alpha=0.10))
    canvas_obj.setFont("Helvetica-Bold", 48)
    canvas_obj.translate(A4[0] / 2, A4[1] / 2)
    canvas_obj.rotate(35)
    canvas_obj.drawCentredString(0, 0, "TEST ONLY - NOT VALID")
    canvas_obj.restoreState()


def create_document(filename: str, title: str, extra_rows: list[tuple[str, str]]):
    path = OUTPUT / filename
    styles = getSampleStyleSheet()
    title_style = ParagraphStyle(
        "Title",
        parent=styles["Title"],
        textColor=colors.HexColor("#00A979"),
        fontSize=24,
        leading=30,
        alignment=TA_CENTER,
        spaceAfter=8 * mm,
    )
    warning_style = ParagraphStyle(
        "Warning",
        parent=styles["BodyText"],
        textColor=colors.HexColor("#B42318"),
        fontSize=12,
        leading=16,
        alignment=TA_CENTER,
        spaceAfter=9 * mm,
    )
    body_style = ParagraphStyle(
        "Body",
        parent=styles["BodyText"],
        textColor=colors.HexColor("#173B36"),
        fontSize=10,
        leading=14,
    )

    doc = SimpleDocTemplate(
        str(path),
        pagesize=A4,
        rightMargin=24 * mm,
        leftMargin=24 * mm,
        topMargin=24 * mm,
        bottomMargin=24 * mm,
        title=f"{title} - TEST ONLY",
        author="Request Ride test pack",
    )
    rows = [
        ("Document purpose", "Request Ride application testing only"),
        ("Full name", DRIVER["Full name"]),
        ("Vehicle", DRIVER["Vehicle"]),
        ("Colour", DRIVER["Colour"]),
        ("Number plate", DRIVER["Number plate"]),
        *extra_rows,
    ]
    table = Table(rows, colWidths=[52 * mm, 92 * mm])
    table.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (0, -1), colors.HexColor("#E4F7F1")),
        ("TEXTCOLOR", (0, 0), (-1, -1), colors.HexColor("#173B36")),
        ("FONTNAME", (0, 0), (0, -1), "Helvetica-Bold"),
        ("FONTNAME", (1, 0), (1, -1), "Helvetica"),
        ("FONTSIZE", (0, 0), (-1, -1), 10),
        ("GRID", (0, 0), (-1, -1), 0.5, colors.HexColor("#80B9AA")),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("TOPPADDING", (0, 0), (-1, -1), 9),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 9),
        ("LEFTPADDING", (0, 0), (-1, -1), 9),
        ("RIGHTPADDING", (0, 0), (-1, -1), 9),
    ]))
    story = [
        Paragraph("REQUEST RIDE", title_style),
        Paragraph(title, styles["Heading1"]),
        Spacer(1, 3 * mm),
        Paragraph(
            "TEST ONLY - FICTIONAL INFORMATION - NOT A VALID LEGAL DOCUMENT",
            warning_style,
        ),
        table,
        Spacer(1, 10 * mm),
        Paragraph(
            "This file was created solely to test document selection, upload, storage, and admin review in the Request Ride development environment. It must not be used for identity verification, driving, insurance, vehicle registration, or any official purpose.",
            body_style,
        ),
    ]
    doc.build(story, onFirstPage=watermark, onLaterPages=watermark)


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for filename, title, rows in DOCUMENTS:
        create_document(filename, title, rows)
    print(f"Created {len(DOCUMENTS)} test PDFs in {OUTPUT}")


if __name__ == "__main__":
    main()
