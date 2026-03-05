#!/usr/bin/env python3
"""
Analyze the PDF structure to understand the content
"""

import pdfplumber

pdf_path = "/Users/Bunny/Downloads/Tyme jan statement.pdf"

with pdfplumber.open(pdf_path) as pdf:
    print(f"Total pages: {len(pdf.pages)}\n")
    
    # Analyze first page in detail
    page = pdf.pages[0]
    
    print("=" * 80)
    print("PAGE 1 TEXT CONTENT:")
    print("=" * 80)
    text = page.extract_text()
    print(text[:2000] if len(text) > 2000 else text)  # First 2000 chars
    
    print("\n" + "=" * 80)
    print("TABLE DETECTION:")
    print("=" * 80)
    
    # Try different table extraction settings
    tables = page.extract_tables()
    print(f"Default extraction found {len(tables)} tables")
    
    # Try with custom settings
    tables_custom = page.extract_tables({
        "vertical_strategy": "lines",
        "horizontal_strategy": "lines",
    })
    print(f"Lines strategy found {len(tables_custom)} tables")
    
    # Try text-based strategy
    tables_text = page.extract_tables({
        "vertical_strategy": "text",
        "horizontal_strategy": "text",
    })
    print(f"Text strategy found {len(tables_text)} tables")
    
    if tables_text:
        print("\nFirst table preview (text strategy):")
        for i, row in enumerate(tables_text[0][:5]):
            print(f"  Row {i}: {row}")
