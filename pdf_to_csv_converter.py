#!/usr/bin/env python3
"""
Convert Tyme bank statement PDF to CSV
"""

import pdfplumber
import csv
import sys
from pathlib import Path

def extract_pdf_to_csv(pdf_path, csv_path):
    """Extract tables from PDF and save to CSV"""
    
    all_rows = []
    
    with pdfplumber.open(pdf_path) as pdf:
        print(f"Processing {len(pdf.pages)} pages...")
        
        for page_num, page in enumerate(pdf.pages, 1):
            print(f"Page {page_num}...")
            
            # Extract tables from the page
            tables = page.extract_tables()
            
            if tables:
                for table in tables:
                    # Filter out empty rows
                    for row in table:
                        if row and any(cell and str(cell).strip() for cell in row):
                            # Clean up cells
                            cleaned_row = [
                                str(cell).strip() if cell else '' 
                                for cell in row
                            ]
                            all_rows.append(cleaned_row)
    
    if not all_rows:
        print("No tables found in PDF!")
        return False
    
    # Write to CSV
    with open(csv_path, 'w', newline='', encoding='utf-8') as csvfile:
        writer = csv.writer(csvfile)
        writer.writerows(all_rows)
    
    print(f"✓ Successfully converted to CSV: {csv_path}")
    print(f"  Total rows: {len(all_rows)}")
    
    return True

if __name__ == "__main__":
    pdf_file = "/Users/Bunny/Downloads/Tyme jan statement.pdf"
    csv_file = "/Users/Bunny/Downloads/Tyme_jan_statement.csv"
    
    if extract_pdf_to_csv(pdf_file, csv_file):
        print(f"\n📄 Preview first few rows:")
        with open(csv_file, 'r', encoding='utf-8') as f:
            for i, line in enumerate(f):
                if i < 10:  # Show first 10 lines
                    print(f"  {line.rstrip()}")
                else:
                    break
    else:
        sys.exit(1)
