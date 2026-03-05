#!/usr/bin/env python3
"""
Final accurate Tyme Bank statement parser
Matches exact column format from the statement
"""

import re
import csv

def clean_number(text):
    """Clean a number string, handling spaces as thousands separators"""
    if not text or text.strip() in ['-', '']:
        return ''
    # Remove spaces used as thousands separators
    return text.strip().replace(' ', '')

def parse_transaction_line(line):
    """
    Parse transaction line with exact column detection
    Format: DD Mon YYYY Description Fees MoneyOut MoneyIn Balance
    
    Key: The last 4 values (or 3-4 values with dashes) are the columns
    Numbers can have spaces like "1 326.57"
    """
    # Extract date (first 11 characters)
    date = line[:11].strip()
    rest = line[11:].strip()
    
    # Strategy: Find the last 4 "tokens" where a token is either:
    # - A dash (-)
    # - A number (possibly multi-part like "1 326.57")
    # Everything before that is the description
    
    # Split into parts
    parts = rest.split()
    
    # Scan from right to left to identify the 4 columns
    # We're looking for: Balance (rightmost), Money In, Money Out, Fees
    columns = []
    i = len(parts) - 1
    
    while i >= 0 and len(columns) < 4:
        part = parts[i]
        
        # Check if this is a column value (number or dash or colon)
        if part in ['-', ':']:
            columns.insert(0, '-')
            i -= 1
        elif re.match(r'^\d+\.\d{2}$', part):  # Like "326.57"
            # Check if previous part is a thousands digit
            if i > 0 and re.match(r'^\d{1,3}$', parts[i-1]):
                # It's spaced thousands like "1 326.57"
                columns.insert(0, parts[i-1] + ' ' + part)
                i -= 2
            else:
                columns.insert(0, part)
                i -= 1
        elif re.match(r'^\d+$', part):  # Like "335" or "1"
            # Could be standalone or part of spaced number
            if i < len(parts) - 1 and re.match(r'^\d{3}\.\d{2}$', parts[i+1]):
                # Already processed as part of previous number
                i -= 1
            else:
                # Check if next has decimal
                if i + 1 < len(parts) and re.match(r'^\d{3}\.\d{2}$', parts[i+1]):
                    # This is first part of spaced number (already added)
                    i -= 1
                else:
                    columns.insert(0, part)
                    i -= 1
        else:
            # Not a column value, rest is description
            break
    
    # Get description (everything before the columns)
    desc_end_idx = i + 1
    description = ' '.join(parts[:desc_end_idx])
    
    # Ensure we have 4 columns (pad with empty if needed)
    while len(columns) < 4:
        columns.insert(0, '')
    
    # Assign columns: Fees, Money Out, Money In, Balance
    fees = clean_number(columns[0])
    money_out = clean_number(columns[1])
    money_in = clean_number(columns[2])
    balance = clean_number(columns[3])
    
    return {
        'date': date,
        'description': description,
        'fees': fees,
        'money_out': money_out,
        'money_in': money_in,
        'balance': balance
    }

def is_transaction_line(line):
    """Check if line starts with a date"""
    return re.match(r'^\d{2} (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{4}', line)

def is_skip_line(line):
    """Check if line should be skipped"""
    skip = [
        '===', 'PAGE BREAK', 'Opening Balance', 'Closing Balance',
        'Date Description Fees', 'TymeBank is', 'Registered Credit',
        'www.tymebank', 'Page ', '0860 999', 'Jellicoe Avenue',
        'Monthly personal', 'BARRIE TERBLANCHE', 'Period', 'Account Num',
        'Branch Code', 'Customer VAT', 'EveryDay account',
        'Make a statement', 'resolution through', 'All fees are',
        'Please inform', 'VAT number', 'Tyme i)', 'qymeOs', 'prane'
    ]
    return any(s in line for s in skip)

def parse_statement(text_file):
    """Main parser"""
    with open(text_file, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    transactions = []
    current = None
    
    for line in lines:
        line = line.rstrip()
        
        if not line.strip() or is_skip_line(line):
            continue
        
        if is_transaction_line(line):
            # Save previous
            if current:
                transactions.append(current)
            
            # Parse new transaction
            current = parse_transaction_line(line)
        
        elif current and line.strip():
            # Multi-line description
            extra = line.strip()
            # Only add substantial text lines (not just numbers/refs)
            if (not re.match(r'^[\d\s\-,.:]+$', extra) and 
                len(extra) > 8 and
                any(word in extra.lower() for word in ['internet', 'amount', 'ref', 'for', 'from', 'returned', 'reversal'])):
                current['description'] += ' ' + extra
    
    # Add last transaction
    if current:
        transactions.append(current)
    
    return transactions

def main():
    input_file = "/Users/Bunny/Downloads/Tyme_jan_statement_raw.txt"
    output_file = "/Users/Bunny/Downloads/Tyme_jan_statement.csv"
    
    print("="*100)
    print(" "*35 + "TYME BANK STATEMENT CONVERTER")
    print("="*100)
    
    print(f"\n📄 Input:  {input_file}")
    print(f"💾 Output: {output_file}\n")
    
    # Parse
    transactions = parse_statement(input_file)
    
    # Save to CSV
    with open(output_file, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=['date', 'description', 'fees', 'money_out', 'money_in', 'balance'])
        writer.writeheader()
        writer.writerows(transactions)
    
    print(f"✓ Extracted {len(transactions)} transactions\n")
    
    # Display sample
    print("="*100)
    print("SAMPLE - FIRST 20 TRANSACTIONS:")
    print("="*100)
    print(f"{'Date':<13} {'Description':<40} {'Fees':<10} {'Out':<12} {'In':<12} {'Balance':<11}")
    print("-" * 100)
    
    for t in transactions[:20]:
        desc = (t['description'][:37] + '...') if len(t['description']) > 40 else t['description']
        print(f"{t['date']:<13} {desc:<40} {t['fees']:<10} {t['money_out']:<12} {t['money_in']:<12} {t['balance']:<11}")
    
    if len(transactions) > 20:
        print(f"\n... and {len(transactions) - 20} more transactions")
    
    # Summary
    print("\n" + "="*100)
    print("FINANCIAL SUMMARY:")
    print("="*100)
    
    try:
        def safe_float(val):
            if not val:
                return 0.0
            return float(val.replace(',', ''))
        
        total_fees = sum(safe_float(t['fees']) for t in transactions)
        total_out = sum(safe_float(t['money_out']) for t in transactions)
        total_in = sum(safe_float(t['money_in']) for t in transactions)
        
        print(f"{'Total Fees:':<20} R {total_fees:>14,.2f}")
        print(f"{'Total Money Out:':<20} R {total_out:>14,.2f}")
        print(f"{'Total Money In:':<20} R {total_in:>14,.2f}")
        print(f"{'-'*38}")
        print(f"{'Net Change:':<20} R {(total_in - total_out - total_fees):>14,.2f}")
        
        if transactions:
            first_balance = safe_float(transactions[0]['balance'])
            last_balance = safe_float(transactions[-1]['balance'])
            
            print(f"\n{'First Balance:':<20} R {first_balance:>14,.2f}")
            print(f"{'Final Balance:':<20} R {last_balance:>14,.2f}")
    except Exception as e:
        print(f"(Summary calculation error: {e})")
    
    print("\n" + "="*100)
    print(f"✓ SUCCESS! CSV file ready at: {output_file}")
    print(f"  Open in Excel, Google Sheets, or any spreadsheet application")
    print("="*100 + "\n")

if __name__ == "__main__":
    main()
