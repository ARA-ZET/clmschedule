#!/usr/bin/env python3
"""
Parse Tyme Bank statement transactions with proper column alignment
Based on the actual statement structure
"""

import re
import csv

def clean_amount(value):
    """Clean amount string - remove spaces and handle dashes"""
    if not value or value.strip() == '-':
        return ''
    # Remove spaces used as thousands separators
    cleaned = value.strip().replace(' ', '')
    return cleaned

def is_transaction_line(line):
    """Check if line starts with a date (DD Mon YYYY format)"""
    date_pattern = r'^\d{2} (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{4}'
    return re.match(date_pattern, line.strip())

def is_noise_line(line):
    """Check if line is noise (headers, page breaks, bank info, etc.)"""
    noise_keywords = [
        'PAGE BREAK',
        'Opening Balance',
        'Closing Balance',
        'Date Description Fees Money',
        'TymeBank is an Authorised',
        'Registered Credit Provider',
        'www.tymebank.co.za',
        'Page 1 of',
        'Page 2 of',
        'Page 3 of',
        'Page 4 of',
        'Page 5 of',
        'Branch Code',
        'ean',
        'Tyme i)',
        'Starr ng',
        'qymeOs',
        'prane',
        'ESANSA WY',
        'Monthly personal',
        'Make a statement',
        'BARRIE TERBLANCHE',
        'Period',
        'Account Num',
        'Customer VAT',
        'EveryDay account',
        'TymeBank \\G NG',
        'resolution through',
        'All fees are inclusive',
        'Please inform us',
        '0860 999 119',
        'Jellicoe Avenue'
    ]
    return any(keyword in line for keyword in noise_keywords)

def parse_transaction_line(line):
    """
    Parse a transaction line with format:
    DD Mon YYYY Description... Fees MoneyOut MoneyIn Balance
    
    Strategy: Extract date first, balance last, then work backwards for amounts
    """
    # Extract date (first 11 characters: "DD Mon YYYY")
    date = line[:11].strip()
    
    # Rest of the line after date
    rest = line[11:].strip()
    
    # Split by multiple spaces to identify columns
    # The rightmost values are: Fees MoneyOut MoneyIn Balance (or subset with dashes)
    parts = rest.split()
    
    # Identify numbers and dashes vs text
    amounts = []
    description_parts = []
    
    # Process from right to left to identify numeric columns
    i = len(parts) - 1
    numeric_count = 0
    
    while i >= 0 and numeric_count < 4:  # Maximum 4 numeric columns (Fees, Out, In, Balance)
        part = parts[i]
        # Check if it's a number or dash
        if part == '-' or re.match(r'^[\d,\.]+$', part.replace(' ', '')):
            amounts.insert(0, part)
            numeric_count += 1
        else:
            # If we've started collecting numbers and hit text, check if it could be
            # part of a number with space (like "2 400.00")
            if numeric_count > 0 and re.match(r'^\d+$', part):
                # This might be part of a spaced number, check next part
                if i + 1 < len(parts) and re.match(r'^\d{3}', parts[i + 1]):
                    # It's part of a spaced number like "2 400"
                    amounts[0] = part + amounts[0]
                    numeric_count -= 1  # Don't count this as a new column
                else:
                    description_parts.insert(0, part)
            else:
                # Rest is description
                description_parts = parts[:i+1]
                break
        i -= 1
    
    # Build description
    description = ' '.join(description_parts)
    
    # Assign amounts to columns (from right: Balance, MoneyIn, MoneyOut, Fees)
    balance = clean_amount(amounts[-1]) if len(amounts) >= 1 else ''
    money_in = clean_amount(amounts[-2]) if len(amounts) >= 2 else ''
    money_out = clean_amount(amounts[-3]) if len(amounts) >= 3 else ''
    fees = clean_amount(amounts[-4]) if len(amounts) >= 4 else ''
    
    return {
        'date': date,
        'description': description,
        'fees': fees,
        'money_out': money_out,
        'money_in': money_in,
        'balance': balance
    }

def parse_tyme_statement(text_file):
    """Parse Tyme Bank statement and extract transactions"""
    
    with open(text_file, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    transactions = []
    current_transaction = None
    
    for line in lines:
        line = line.rstrip()
        
        # Skip empty lines
        if not line.strip():
            continue
        
        # Skip noise lines
        if is_noise_line(line):
            continue
        
        # Check if this is a transaction line
        if is_transaction_line(line):
            # Save previous transaction
            if current_transaction:
                transactions.append(current_transaction)
            
            # Parse new transaction
            current_transaction = parse_transaction_line(line)
        
        elif current_transaction and line.strip():
            # This might be a continuation of the description
            # Check if it's not a standalone number or reference line
            if not re.match(r'^[\d\s\-,\.]+$', line.strip()):
                # Add to description if it looks like text
                extra_desc = line.strip()
                # Skip common OCR noise
                if extra_desc and len(extra_desc) > 2:
                    current_transaction['description'] += ' ' + extra_desc
    
    # Add the last transaction
    if current_transaction:
        transactions.append(current_transaction)
    
    return transactions

def save_to_csv(transactions, csv_file):
    """Save transactions to CSV"""
    fieldnames = ['date', 'description', 'fees', 'money_out', 'money_in', 'balance']
    
    with open(csv_file, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(transactions)

def main():
    text_file = "/Users/Bunny/Downloads/Tyme_jan_statement_raw.txt"
    csv_file = "/Users/Bunny/Downloads/Tyme_jan_statement.csv"
    
    print("="*80)
    print("PARSING TYME BANK STATEMENT TRANSACTIONS")
    print("="*80)
    
    # Parse transactions
    print("\nExtracting transactions from OCR text...")
    transactions = parse_tyme_statement(text_file)
    
    # Save to CSV
    save_to_csv(transactions, csv_file)
    
    print(f"✓ Extracted {len(transactions)} transactions")
    print(f"✓ Saved to: {csv_file}")
    
    # Show preview
    print("\n" + "="*80)
    print("PREVIEW (first 15 transactions):")
    print("="*80)
    print(f"{'Date':<14} {'Description':<45} {'Fees':<10} {'Out':<12} {'In':<12} {'Balance':<12}")
    print("-" * 80)
    
    for trans in transactions[:15]:
        desc = trans['description'][:43] + '..' if len(trans['description']) > 45 else trans['description']
        print(f"{trans['date']:<14} {desc:<45} {trans['fees']:<10} {trans['money_out']:<12} {trans['money_in']:<12} {trans['balance']:<12}")
    
    if len(transactions) > 15:
        print(f"\n... and {len(transactions) - 15} more transactions")
    
    # Show summary statistics
    print("\n" + "="*80)
    print("SUMMARY:")
    print("="*80)
    
    total_fees = sum(float(t['fees'].replace(',', '')) for t in transactions if t['fees'])
    total_out = sum(float(t['money_out'].replace(',', '')) for t in transactions if t['money_out'])
    total_in = sum(float(t['money_in'].replace(',', '')) for t in transactions if t['money_in'])
    
    print(f"Total Transactions: {len(transactions)}")
    print(f"Total Fees:        R {total_fees:,.2f}")
    print(f"Total Money Out:   R {total_out:,.2f}")
    print(f"Total Money In:    R {total_in:,.2f}")
    print(f"Net Change:        R {total_in - total_out - total_fees:,.2f}")
    
    if transactions:
        print(f"\nOpening Balance:   R {transactions[0]['balance']}")
        print(f"Closing Balance:   R {transactions[-1]['balance']}")

if __name__ == "__main__":
    main()
