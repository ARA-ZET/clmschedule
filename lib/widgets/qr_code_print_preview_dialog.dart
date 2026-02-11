import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../models/inventory_tool.dart';
import '../services/qr_code_pdf_service.dart';

class QrCodePrintPreviewDialog extends StatefulWidget {
  final List<InventoryTool> tools;

  const QrCodePrintPreviewDialog({
    super.key,
    required this.tools,
  });

  @override
  State<QrCodePrintPreviewDialog> createState() =>
      _QrCodePrintPreviewDialogState();
}

class _QrCodePrintPreviewDialogState extends State<QrCodePrintPreviewDialog> {
  int _codesPerRow = 4;
  double _qrSize = 150.0;
  bool _isGenerating = false;
  late Set<String> _selectedToolIds;
  bool _isSelectionExpanded = false;

  @override
  void initState() {
    super.initState();
    // Initially select all tools
    _selectedToolIds = widget.tools.map((t) => t.id).toSet();
  }

  bool get _allSelected => _selectedToolIds.length == widget.tools.length;
  bool get _someSelected => _selectedToolIds.isNotEmpty && !_allSelected;

  void _toggleAll() {
    setState(() {
      if (_allSelected) {
        _selectedToolIds.clear();
      } else {
        _selectedToolIds = widget.tools.map((t) => t.id).toSet();
      }
    });
  }

  void _toggleTool(String toolId) {
    setState(() {
      if (_selectedToolIds.contains(toolId)) {
        _selectedToolIds.remove(toolId);
      } else {
        _selectedToolIds.add(toolId);
      }
    });
  }

  List<InventoryTool> get _selectedTools =>
      widget.tools.where((t) => _selectedToolIds.contains(t.id)).toList();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.9,
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.orange.shade700, Colors.orange.shade500],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.print,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'QR Code Print Preview',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        Text(
                          '${_selectedToolIds.length} of ${widget.tools.length} tools selected',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),

            // Controls
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                border: Border(
                  bottom: BorderSide(color: Colors.grey.shade300),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Tool Selection Header - Collapsable
                  InkWell(
                    onTap: () {
                      setState(() {
                        _isSelectionExpanded = !_isSelectionExpanded;
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(
                                _isSelectionExpanded
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                                size: 24,
                              ),
                              const SizedBox(width: 8),
                              const Text(
                                'Tool Selection',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.orange.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '${_selectedToolIds.length}/${widget.tools.length}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.orange,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          TextButton.icon(
                            onPressed: _toggleAll,
                            icon: Icon(
                              _allSelected
                                  ? Icons.check_box
                                  : (_someSelected
                                      ? Icons.indeterminate_check_box
                                      : Icons.check_box_outline_blank),
                              size: 20,
                            ),
                            label: Text(
                                _allSelected ? 'Deselect All' : 'Select All'),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.orange,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Collapsable Tool Grid
                  if (_isSelectionExpanded) ...[
                    const SizedBox(height: 8),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 300),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          // Calculate how many items can fit per row
                          const minItemWidth = 200.0;
                          final crossAxisCount =
                              (constraints.maxWidth / minItemWidth)
                                  .floor()
                                  .clamp(1, 6);

                          return GridView.builder(
                            padding: const EdgeInsets.all(8),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: crossAxisCount,
                              childAspectRatio: 4,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                            ),
                            shrinkWrap: true,
                            itemCount: widget.tools.length,
                            itemBuilder: (context, index) {
                              final tool = widget.tools[index];
                              final isSelected =
                                  _selectedToolIds.contains(tool.id);
                              return InkWell(
                                onTap: () => _toggleTool(tool.id),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? Colors.orange.shade50
                                        : Colors.grey.shade50,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: isSelected
                                          ? Colors.orange
                                          : Colors.grey.shade300,
                                      width: isSelected ? 2 : 1,
                                    ),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          isSelected
                                              ? Icons.check_box
                                              : Icons.check_box_outline_blank,
                                          color: isSelected
                                              ? Colors.orange
                                              : Colors.grey,
                                          size: 20,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Text(
                                                tool.toolId,
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.bold,
                                                  color: isSelected
                                                      ? Colors.orange.shade900
                                                      : Colors.black87,
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              Text(
                                                tool.name,
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  color: Colors.grey.shade600,
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                                maxLines: 1,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ],
                  const Divider(height: 32),
                  const Text(
                    'Layout Settings',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'QR Codes per Row: $_codesPerRow',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            Slider(
                              value: _codesPerRow.toDouble(),
                              min: 4,
                              max: 8,
                              divisions: 3,
                              label: '$_codesPerRow',
                              onChanged: (value) {
                                setState(() {
                                  _codesPerRow = value.round();
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 24),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'QR Code Size: ${_qrSize.round()}px',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            Slider(
                              value: _qrSize,
                              min: 100,
                              max: 250,
                              divisions: 15,
                              label: '${_qrSize.round()}px',
                              onChanged: (value) {
                                setState(() {
                                  _qrSize = value;
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline,
                            size: 16, color: Colors.blue.shade700),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Approximate: ${(_codesPerRow * ((MediaQuery.of(context).size.height - 300) / _qrSize).floor()).round()} codes per page (${_selectedToolIds.length} selected)',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.blue.shade700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Preview
            Expanded(
              child: Stack(
                children: [
                  Container(
                    color: Colors.grey.shade200,
                    padding: const EdgeInsets.all(16),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 10,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: ListView(
                        padding: const EdgeInsets.all(24),
                        children: _buildPreviewPages(),
                      ),
                    ),
                  ),
                  if (_isGenerating)
                    Container(
                      color: Colors.black54,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.all(32),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(
                                valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.orange),
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                'Generating PDF...',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Creating QR codes for ${_selectedToolIds.length} tools',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // Footer Actions
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border(
                  top: BorderSide(color: Colors.grey.shade300),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 5,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: _isGenerating || _selectedToolIds.isEmpty
                        ? null
                        : _generatePdf,
                    icon: _isGenerating
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.picture_as_pdf),
                    label: Text(_isGenerating
                        ? 'Generating...'
                        : 'Download PDF (${_selectedToolIds.length})'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildPreviewPages() {
    // Calculate A4 LANDSCAPE page dimensions in pixels (approx 96 DPI)
    const double pageWidthPx = 1123; // A4 landscape width at 96 DPI
    const double pageHeightPx = 794; // A4 landscape height at 96 DPI
    const double marginPx = 40;

    final availableWidth = pageWidthPx - (marginPx * 2);
    final availableHeight = pageHeightPx - (marginPx * 2);

    final itemWidth = availableWidth / _codesPerRow;
    final itemsPerRow = _codesPerRow;
    final rowsPerPage = (availableHeight / itemWidth).floor();
    final itemsPerPage = itemsPerRow * rowsPerPage;

    // Only show selected tools
    final toolsToShow = _selectedTools;

    // Group tools by page
    final pages = <List<InventoryTool>>[];
    for (int i = 0; i < toolsToShow.length; i += itemsPerPage) {
      pages.add(
        toolsToShow.sublist(
          i,
          (i + itemsPerPage) < toolsToShow.length
              ? i + itemsPerPage
              : toolsToShow.length,
        ),
      );
    }

    final pageWidgets = <Widget>[];
    for (int pageNum = 0; pageNum < pages.length; pageNum++) {
      pageWidgets.add(
        Container(
          width: pageWidthPx,
          height: pageHeightPx,
          margin: const EdgeInsets.only(bottom: 24),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade400, width: 2),
            color: Colors.white,
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Wrap(
              spacing: 5,
              runSpacing: 5,
              children: pages[pageNum].map((tool) {
                return _buildQrCodePreview(tool, itemWidth);
              }).toList(),
            ),
          ),
        ),
      );
    }

    return pageWidgets;
  }

  Widget _buildQrCodePreview(InventoryTool tool, double size) {
    return Container(
      width: size,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade400, width: 1),
        color: Colors.white,
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // QR Code
          SizedBox(
            width: size - 16,
            height: size - 16,
            child: QrImageView(
              data: tool.qrCode,
              version: QrVersions.auto,
            ),
          ),
          const SizedBox(height: 12),
          // Tool ID - Bold and prominent
          Container(
            width: size - 16,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              tool.toolId,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Tool Name - Bold
          Container(
            width: size - 16,
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              tool.name,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _generatePdf() async {
    if (_selectedToolIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select at least one tool to print'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    setState(() => _isGenerating = true);

    try {
      await QrCodePdfService.downloadQrCodePdf(
        _selectedTools,
        codesPerRow: _codesPerRow,
        qrSize: _qrSize,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'PDF generated successfully with ${_selectedToolIds.length} QR codes!'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error generating PDF: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isGenerating = false);
      }
    }
  }
}
