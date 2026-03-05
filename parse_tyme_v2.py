#!/usr/bin/env python3
"""
Parse Tyme Bank statement with position-based column detection
"""

import re
import csv

def is_transaction_line(line):
    """Check if line starts with a transaction date"""
    return re.match(r'^\d{2} (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{4}', line)

def is_noise_line(line):
    """Check if line should be skipped"""
    noise = [
        '===', 'PAGE BREAK', 'Opening Balance', 'Closing Balance',
        'Date Description Fees', 'TymeBank is an', 'Registered Credit',
        'www.tymebank.co.za', 'Page ', 'Branch', '0860 999 119',
        'Jellicoe Avenue', 'VAT number', 'Monthly personal',
        'Make a statement', 'BARRIE TERBLANCHE', 'Period', 'Account Num',
        'Customer VAT', 'EveryDay account', 'resolution through',
        'All fees are inclusive', 'Please inform'
    ]
    return any(n in line for n in noise)

def extract_amount(text):
    """Extract amount from text, handling spaces in numbers"""
    if not text or text.strip() == '-':
        return ''
    # Remove extra spaces and clean
    cleaned = text.strip().replace(' ', '')
    # Check if it's a valid number
    if re.match(r'^[\d,\.]+$', cleaned):
        return cleaned
    return ''

def parse_transaction(line):
    """
    Parse transaction using pattern matching for the columns
    Format: DD Mon YYYY Description... Fees MoneyOut MoneyIn Balance
    """
    # Extract date (positions 0-11)
    date = line[:11].strip()
    
    # Get the rest of the line
    rest = line[11:].strip()
    
    # Find all number patterns (including spaced numbers like "2 400.00")
    # Pattern: optional dash, digits with optional spaces and decimals
    number_pattern = r'-?\s*\d[\d\s]*(?:\s\d{3})*(?:\.\d{2})?'
    
    # Find all potential numbers in the line
    matches = list(re.finditer(number_pattern, rest))
    
    # The rightmost numbers are our columns (Balance is rightmost)
    # Work backwards to identify: Balance, MoneyIn, MoneyOut, Fees
    amounts = []
    for match in reversed(matches):
        value = match.group().strip()
        # Clean up the number
        cleaned = value.replace(' ', '')
        # Only keep if it looks like a proper amount
        if cleaned and (cleaned == '-' or re.match(r'^-?[\d,\.]+$', cleaned)):
            amounts.insert(0, cleaned)
            if len(amounts) >= 4:  # We have all columns
                break
    
    # Get description (everything before the first column number)
    if matches and len(matches) >= len(amounts):
        # Find where numbers start
        first_num_pos = matches[-len(amounts)].start()
        description = rest[:first_num_pos].strip()
    else:
        # Fallback: split by multiple spaces
        parts = rest.split('  ')
        description = parts[0].strip() if parts else rest
    
    # Assign columns (from left to right in amounts list)
    # Could be: [fees, out, in, balance] or [out, in, balance] or [in, balance] etc.
    balance = amounts[-1] if amounts else ''
    
    # Determine which columns we have based on count and dash positions
    if len(amounts) == 4:
        fees, money_out, money_in, balance = amounts
    elif len(amounts) == 3:
        # Could be: [fees, moneyOut, balance] or [moneyOut, moneyIn, balance]
        # Check middle value - if it's a dash, structure varies
        if amounts[0] == '-':
            fees, money_out, money_in = '', amounts[1], ''
        elif amounts[1] == '-':
            fees, money_out, money_in = amounts[0], '', ''
        else:
            # Most likely: moneyOut, moneyIn, balance
            fees, money_out, money_in = '', amounts[0], amounts[1]
    elif len(amounts) == 2:
        fees, money_out, money_in = '', amounts[0], ''
    else:
        fees, money_out, money_in = '', '', ''
    
    # Clean amounts (remove dashes)
    fees = fees if fees != '-' else ''
    money_out = money_out if money_out != '-' else ''
    money_in = money_in if money_in != '-' else ''
    
    return {
        'date': date,
        'description': description,
        'fees': fees,
        'money_out': money_out,
        'money_in': money_in,
        'balance': balance
    }

def parse_statement(text_file):
    """Main parsing function"""
    with open(text_file, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    transactions = []
    current_trans = None
    
    for line in lines:
        line = line.rstrip()
        
        if not line.strip() or is_noise_line(line):
            continue
        
        if is_transaction_line(line):
            # Save previous transaction
            if current_trans:
                transactions.append(current_trans)
            
            # Parse new transaction
            current_trans = parse_transaction(line)
        elif current_trans and line.strip():
            # Append to description if it's text (not just numbers/refs)
            stripped = line.strip()
            # Skip OCR artifacts and reference numbers
            if (not re.match(r'^[\d\s\-,\.]+$', stripped) and 
                len(stripped) > 3 and
                'Ref' in stripped or 'for' in stripped or 'from' in stripped or 
                len(stripped) > 15):
                current_trans['description'] += ' ' + stripped
    
    if current_trans:
        transactions.append(current_trans)
    
    return transactions

def main():
    text_file = "/Users/Bunny/Downloads/Tyme_jan_statement_raw.txt"
    csv_file = "/Users/Bunny/Downloads/Tyme_jan_statement.csv"
    
    print("Parsing Tyme Bank statement...")
    
    transactions = parse_statement(text_file)
    
    # Save to CSV
    with open(csv_file, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=['date', 'description', 'fees', 'money_out', 'money_in', 'balance'])
        writer.writeheader()
        writer.writerows(transactions)
    
    print(f"✓ Extracted {len(transactions)} transactions")
    print(f"✓ CSV saved to: {csv_file}")
    
    # Preview
    print("\nFirst 10 transactions:")
    print("-" * 100)
    for i, t in enumerate(transactions[:10], 1):
        print(f"{i:2}. {t['date']:<12} | {t['description'][:40]:<40} | F:{t['fees']:<8} Out:{t['money_out']:<10} In:{t['money_in']:<10} | Bal:{t['balance']}")

if __name__ == "__main__":
    main()
