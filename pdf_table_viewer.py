#!/usr/bin/env python3
"""
Extract and display table data from PDF
"""

import pdfplumber

pdf_path = "/Users/Bunny/Downloads/Tyme jan statement.pdf"

with pdfplumber.open(pdf_path) as pdf:
    print(f"Total pages: {len(pdf.pages)}\n")
    
    for page_num, page in enumerate(pdf.pages, 1):
        print(f"\n{'=' * 80}")
        print(f"PAGE {page_num}")
        print(f"{'=' * 80}")
        
        # Try default table extraction
        tables = page.extract_tables()
        
        if tables:
            for table_num, table in enumerate(tables, 1):
                print(f"\nTable {table_num} ({len(table)} rows):")
                print("-" * 80)
                
                # Show first 10 rows
                for i, row in enumerate(table[:10]):
                    print(f"Row {i}: {row}")
                
                if len(table) > 10:
                    print(f"... ({len(table) - 10} more rows)")
        else:
            print("No tables found on this page")
            
            # Try to extract text
            text = page.extract_text()
            if text:
                print("\nText content preview:")
                print(text[:500])
