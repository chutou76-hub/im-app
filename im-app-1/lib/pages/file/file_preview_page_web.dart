import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/app_config.dart';
import '../../services/group_file_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_dialogs.dart';

/// 文件预览页（Web 端降级实现）。
///
/// Web 平台不支持 [pdfx] / [photo_view]（无 PDF 渲染 / Canvas 缩放），
/// 这里退化为：拉取预览元信息，拿到 url 后引导用系统浏览器打开（下载/查看）。
class FilePreviewPage extends StatefulWidget {
  final GroupFileItem item;
  final String convId;
  final String convName;

  const FilePreviewPage({
    super.key,
    required this.item,
    required this.convId,
    this.convName = '',
  });

  @override
  State<FilePreviewPage> createState() => _FilePreviewPageState();
}

class _FilePreviewPageState extends State<FilePreviewPage> {
  final _svc = GroupFileService.instance;
  bool _loading = true;
  String _url = '';
  bool _notSupported = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await _svc.preview(widget.item.fileId);
      final status = (data['status'] ?? '').toString();
      if (status != 'ready') {
        setState(() {
          _loading = false;
          _notSupported = true;
          _url = '';
        });
        return;
      }
      setState(() {
        _url = _abs((data['url'] ?? '').toString());
        _loading = false;
        _notSupported = _url.isEmpty;
      });
    } catch (_) {
      setState(() {
        _loading = false;
        _notSupported = true;
      });
    }
  }

  String _abs(String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    final base = AppConfig.instance.apiBase;
    if (base.endsWith('/')) {
      return '$base${url.startsWith('/') ? url.substring(1) : url}';
    }
    return '$base${url.startsWith('/') ? url : '/$url'}';
  }

  Future<void> _open() async {
    final uri = Uri.tryParse(_url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) AppDialogs.toast(context, '打开失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: context.cs.surface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 26, color: Color(0xFF111111)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(widget.item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: Color(0xFF111111))),
        centerTitle: true,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_loading)
                const CircularProgressIndicator(color: AppTheme.primary)
              else if (_notSupported)
                Column(
                  children: [
                    Icon(Icons.file_open_outlined,
                        size: 52, color: context.cs.onSurfaceVariant),
                    const SizedBox(height: 12),
                    Text('当前平台暂不支持预览，请用 App 或浏览器打开',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 15, color: context.cs.onSurfaceVariant)),
                  ],
                )
              else
                Column(
                  children: [
                    Icon(Icons.open_in_browser_outlined,
                        size: 52, color: AppTheme.primary),
                    const SizedBox(height: 12),
                    Text('网页端暂不支持内联预览',
                        style: TextStyle(
                            fontSize: 15, color: context.cs.onSurfaceVariant)),
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: _open,
                      icon: const Icon(Icons.open_in_browser, size: 18),
                      label: const Text('用浏览器打开'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
