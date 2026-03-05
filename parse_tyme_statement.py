#!/usr/bin/env python3
"""
Parse Tyme Bank statement format and convert to CSV
"""

import csv
import re

def parse_tyme_bank_statement(text_file, csv_file):
    """Parse Tyme Bank statement format"""
    
    with open(text_file, 'r', encoding='utf-8') as f:
        text = f.read()
    
    transactions = []
    lines = text.split('\n')
    
    # Pattern for transaction lines: date at start
    date_pattern = r'^\d{2} [A-Z][a-z]{2} \d{4}'
    
    current_transaction = None
    
    for line in lines:
        line = line.strip()
        
        # Check if line starts with a date
        if re.match(date_pattern, line):
            # Save previous transaction if exists
            if current_transaction:
                transactions.append(current_transaction)
            
            # Parse new transaction
            parts = line.split()
            if len(parts) >= 3:
                date = f"{parts[0]} {parts[1]} {parts[2]}"  # e.g., "01 Jan 2026"
                
                # Rest is description and amounts
                remaining = ' '.join(parts[3:])
                
                # Extract amounts - look for patterns like "- 335.04" or "2 400.00"
                # Split by multiple spaces to separate columns
                amount_parts = remaining.split()
                
                # Initialize transaction
                current_transaction = {
                    'date': date,
                    'description': '',
                    'fees': '',
                    'money_out': '',
                    'money_in': '',
                    'balance': ''
                }
                
                # Try to extract amounts from the end (balance, money in/out, fees)
                # Balance is usually the last number
                # Work backwards to identify columns
                numbers = []
                desc_parts = []
                
                for i, part in enumerate(amount_parts):
                    # Check if it looks like a number (with or without commas)
                    if re.match(r'^-?[\d,]+\.?\d*$', part.replace(',', '')):
                        numbers.append(part. replace(' ', ''))
                    elif part == '-':
                        numbers.append(part)
                    else:
                        desc_parts.append(part)
                
                # Description is everything before the numbers
                current_transaction['description'] = ' '.join(desc_parts)
                
                # Assign numbers based on position (right to left)
                # Typically: [fees] [money_out] [money_in] balance
                if len(numbers) >= 1:
                    current_transaction['balance'] = numbers[-1]
                if len(numbers) >= 2:
                    # Could be money_in or money_out
                    val = numbers[-2]
                    if val != '-':
                        # Check if it's positive (money in) or in the money_in position
                        current_transaction['money_in'] = val
                if len(numbers) >= 3:
                    val = numbers[-3]
                    if val != '-':
                        current_transaction['money_out'] = val
                if len(numbers) >= 4:
                    val = numbers[-4]
                    if val != '-':
                        current_transaction['fees'] = val
                        
        elif current_transaction and line:
            # Continuation of description (multi-line transactions)
            if not re.match(r'^[\d\s,.-]+$', line):  # Skip lines with only numbers
                current_transaction['description'] += ' ' + line
    
    # Add the last transaction
    if current_transaction:
        transactions.append(current_transaction)
    
    # Write to CSV
    fieldnames = ['date', 'description', 'fees', 'money_out', 'money_in', 'balance']
    
    with open(csv_file, 'w', newline='', encoding='utf-8') as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(transactions)
    
    return transactions

def main():
    text_file = "/Users/Bunny/Downloads/Tyme_jan_statement_raw.txt"
    csv_file = "/Users/Bunny/Downloads/Tyme_jan_statement.csv"
    
    print("Parsing Tyme Bank statement...")
    transactions = parse_tyme_bank_statement(text_file, csv_file)
    
    print(f"✓ Extracted {len(transactions)} transactions")
    print(f"✓ Saved to: {csv_file}")
    
    # Show preview
    print("\n" + "="*80)
    print("PREVIEW (first 10 transactions):")
    print("="*80)
    
    for i, trans in enumerate(transactions[:10], 1):
        print(f"\n{i}. {trans['date']}")
        print(f"   {trans['description']}")
        if trans['fees']:
            print(f"   Fees: R{trans['fees']}")
        if trans['money_out']:
            print(f"   Out:  R{trans['money_out']}")
        if trans['money_in']:
            print(f"   In:   R{trans['money_in']}")
        print(f"   Balance: R{trans['balance']}")
    
    if len(transactions) > 10:
        print(f"\n... and {len(transactions) - 10} more transactions")

if __name__ == "__main__":
    main()
