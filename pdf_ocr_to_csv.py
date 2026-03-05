#!/usr/bin/env python3
"""
Convert scanned bank statement PDF to CSV using OCR
"""

import pytesseract
from pdf2image import convert_from_path
import csv
import re
from pathlib import Path

def extract_text_from_pdf_ocr(pdf_path):
    """Extract text from scanned PDF using OCR"""
    print(f"Converting PDF pages to images...")
    images = convert_from_path(pdf_path, dpi=300)
    
    all_text = []
    for i, image in enumerate(images, 1):
        print(f"Processing page {i}/{len(images)} with OCR...")
        text = pytesseract.image_to_string(image, lang='eng')
        all_text.append(text)
    
    return "\n\n=== PAGE BREAK ===\n\n".join(all_text)

def parse_bank_statement(text):
    """
    Parse bank statement text and extract transactions
    This is a generic parser - may need adjustment based on actual format
    """
    lines = text.split('\n')
    transactions = []
    
    # Common patterns for bank transactions
    # Date formats: DD/MM/YYYY, DD-MM-YYYY, YYYY-MM-DD
    # Amount formats: 1,234.56 or -1,234.56
    date_pattern = r'\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|\d{4}[/-]\d{1,2}[/-]\d{1,2}'
    amount_pattern = r'-?\d{1,3}(?:,?\d{3})*\.\d{2}'
    
    for line in lines:
        line = line.strip()
        if not line:
            continue
        
        # Look for lines with dates and amounts
        dates = re.findall(date_pattern, line)
        amounts = re.findall(amount_pattern, line)
        
        if dates and amounts:
            # Extract description (text between date and amount)
            parts = re.split(date_pattern + '|' + amount_pattern, line)
            description = ' '.join(p.strip() for p in parts if p and p.strip())
            
            transactions.append({
                'date': dates[0],
                'description': description,
                'amount': amounts[-1],  # Last amount is usually the main one
                'balance': amounts[-1] if len(amounts) > 1 else ''
            })
    
    return transactions

def save_to_csv(transactions, csv_path):
    """Save transactions to CSV file"""
    if not transactions:
        print("No transactions found!")
        return False
    
    fieldnames = ['date', 'description', 'amount', 'balance']
    
    with open(csv_path, 'w', newline='', encoding='utf-8') as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(transactions)
    
    return True

def main():
    pdf_file = "/Users/Bunny/Downloads/Tyme jan statement.pdf"
    csv_file = "/Users/Bunny/Downloads/Tyme_jan_statement.csv"
    text_file = "/Users/Bunny/Downloads/Tyme_jan_statement_raw.txt"
    
    print("="*60)
    print("BANK STATEMENT PDF TO CSV CONVERTER (with OCR)")
    print("="*60)
    
    # Extract text using OCR
    print("\n1. Extracting text from scanned PDF...")
    full_text = extract_text_from_pdf_ocr(pdf_file)
    
    # Save raw OCR text for reference
    with open(text_file, 'w', encoding='utf-8') as f:
        f.write(full_text)
    print(f"   ✓ Raw OCR text saved to: {text_file}")
    
    # Parse transactions
    print("\n2. Parsing transactions...")
    transactions = parse_bank_statement(full_text)
    print(f"   ✓ Found {len(transactions)} potential transactions")
    
    # Save to CSV
    print("\n3. Saving to CSV...")
    if save_to_csv(transactions, csv_file):
        print(f"   ✓ CSV file saved to: {csv_file}")
        
        # Show preview
        print("\n" + "="*60)
        print("PREVIEW (first 10 transactions):")
        print("="*60)
        for i, trans in enumerate(transactions[:10], 1):
            print(f"\n{i}. Date: {trans['date']}")
            print(f"   Desc: {trans['description']}")
            print(f"   Amt:  {trans['amount']}")
            if trans['balance']:
                print(f"   Bal:  {trans['balance']}")
    else:
        print("   ✗ No transactions found to save")
        print("\n⚠️  The PDF might need manual processing.")
        print(f"   Check raw OCR output in: {text_file}")

if __name__ == "__main__":
    main()
