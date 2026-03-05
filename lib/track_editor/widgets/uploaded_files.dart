// track_editor/widgets/uploaded_files.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/te_files_provider.dart';

class TEUploadedFiles extends StatelessWidget {
  const TEUploadedFiles({super.key});

  @override
  Widget build(BuildContext context) {
    final selectedFileNames =
        context.watch<TEFilesProvider>().selectedFileNames;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade200, width: 2),
        borderRadius: BorderRadius.circular(10),
      ),
      width: 400,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Files',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          ...selectedFileNames.map(
            (name) => Text(
              name,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
