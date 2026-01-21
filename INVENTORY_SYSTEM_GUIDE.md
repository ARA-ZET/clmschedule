# Happy Sun Inventory System

A comprehensive inventory management system for window cleaning tools with QR code functionality.

## Features

### 1. Tool Management

- Add, edit, and delete tools
- Upload tool images
- Categorize tools (Squeegees, Buckets, Ladders, Poles, Cloths, Chemicals, Safety Equipment, Other)
- Track total quantity and available quantity
- Monitor tools currently in use

### 2. QR Code System

- **Generate QR Codes**: Each tool automatically gets a unique QR code
- **Print Labels**: View and print QR code labels to attach to physical tools
- **Scan Tools**: Use mobile camera to scan QR codes and quickly access tool information

### 3. Project Assignment

- Assign tools to projects (coming soon)
- Track which tools are out with teams
- Return tools from projects
- View tool usage history

## Usage

### Adding a New Tool

1. Navigate to **Happy Sun > Inventory** tab
2. Click the **"Add Tool"** button
3. Fill in the tool details:
   - Name (required)
   - Category (required)
   - Quantity (required)
   - Description (optional)
   - Upload an image (optional)
4. Click **"Add Tool"** to save

### Generating QR Code Labels

1. Click on any tool card to view details
2. In the tool details dialog, click **"View & Print QR Code"**
3. The QR code will be displayed
4. Click **"Print Label"** to print the QR code label
5. Attach the printed label to your physical tool

### Scanning Tools

1. Click the **"Scan QR"** button in the inventory view
2. Position the camera so the QR code is within the frame
3. The app will automatically detect the QR code and show the tool details
4. Use the flash toggle if needed in low-light conditions

### Filtering Tools

- Use the **Category** dropdown to filter tools by category
- Select "All" to view all tools

## Tool Categories

- **Squeegees**: Window cleaning squeegees of various sizes
- **Buckets**: Water buckets and containers
- **Ladders**: Extension ladders and step ladders
- **Poles**: Extension poles and water-fed poles
- **Cloths**: Microfiber cloths, scrim, and cleaning cloths
- **Chemicals**: Cleaning solutions and detergents
- **Safety Equipment**: Harnesses, gloves, safety glasses
- **Other**: Miscellaneous tools

## Data Structure

Tools are stored in the `inventoryTools` Firebase collection with the following fields:

- `name`: Tool name
- `description`: Tool description
- `imageUrl`: URL to tool image in Firebase Storage
- `category`: Tool category
- `quantity`: Total quantity owned
- `availableQuantity`: Currently available quantity
- `qrCode`: Unique QR code identifier
- `createdAt`: Creation timestamp
- `lastUsed`: Last usage timestamp
- `currentProjects`: Array of project IDs where tool is assigned

## Dependencies

- `mobile_scanner: ^5.2.3` - QR code scanning
- `qr_flutter: ^4.1.0` - QR code generation

## Future Enhancements

- [ ] Firebase Storage integration for image uploads
- [ ] Project assignment workflow
- [ ] Tool maintenance tracking
- [ ] Low stock alerts
- [ ] Tool check-out/check-in system
- [ ] Usage history and reports
- [ ] Barcode support (in addition to QR codes)
- [ ] Bulk import/export tools
