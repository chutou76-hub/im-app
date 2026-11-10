import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../theme/app_theme.dart';

/// 省市区三级选择器（2026-11-07 朋友圈地区需求）：
/// 数据 assets/region/pca.json（{省: {市: [区...]}}，Gitee modood/Administrative-divisions-of-China），
/// 不对接任何地图 API。选择「区」即确认返回 [省, 市, 区]；
/// 若某市无区列表则选「市」即确认。
class RegionPickerSheet {
  RegionPickerSheet._();

  static Map<String, dynamic>? _cache;

  static Future<Map<String, dynamic>> _load() async {
    if (_cache != null) return _cache!;
    final raw = await rootBundle.loadString('assets/region/pca.json');
    _cache = json.decode(raw) as Map<String, dynamic>;
    return _cache!;
  }

  /// 打开选择器；返回 ['省', '市', '区'] 或 null（取消）
  static Future<List<String>?> show(BuildContext context) {
    return showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _RegionPicker(),
    );
  }
}

class _RegionPicker extends StatefulWidget {
  const _RegionPicker();

  @override
  State<_RegionPicker> createState() => _RegionPickerState();
}

class _RegionPickerState extends State<_RegionPicker> {
  Map<String, dynamic> _data = {};
  bool _loading = true;
  String _province = '';
  String _city = '';

  List<String> get _provinceList => _data.keys.toList();
  List<String> get _cityList =>
      _province.isEmpty ? [] : ((_data[_province] as Map?)?.keys.toList().cast<String>() ?? []);
  List<String> get _districtList {
    if (_city.isEmpty) return [];
    final v = (_data[_province] as Map?)?[_city];
    if (v is List) return v.map((e) => e.toString()).toList();
    return [];
  }

  @override
  void initState() {
    super.initState();
    RegionPickerSheet._load().then((d) {
      if (mounted) setState(() { _data = d; _loading = false; });
    }).catchError((_) {
      if (mounted) setState(() => _loading = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return SafeArea(
      child: Container(
        height: MediaQuery.of(context).size.height * 0.55,
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Column(
          children: [
            // 标题栏
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.4))),
              ),
              child: Row(children: [
                Expanded(
                  child: Text(
                    _crumb(),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
              ]),
            ),
            if (_loading)
              const Expanded(child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
            else ...[
              Expanded(child: _column(_provinceList, _onPickProvince,
                  selected: _province)),
              Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.4)),
              Expanded(child: _column(_cityList, _onPickCity, selected: _city)),
              Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.4)),
              Expanded(child: _column(_districtList, _onPickDistrict)),
            ],
          ],
        ),
      ),
    );
  }

  String _crumb() {
    if (_city.isNotEmpty) return '$_province · $_city';
    if (_province.isNotEmpty) return _province;
    return '选择所在地区';
  }

  void _onPickProvince(String p) => setState(() { _province = p; _city = ''; });

  void _onPickCity(String c) {
    final ds = _districtListOf(_province, c);
    if (ds.isEmpty) {
      // 无区县数据（如直辖市部分场景）→ 选市即确认
      Navigator.pop(context, [_province, c, '']);
      return;
    }
    setState(() => _city = c);
  }

  void _onPickDistrict(String d) => Navigator.pop(context, [_province, _city, d]);

  List<String> _districtListOf(String p, String c) {
    final v = (_data[p] as Map?)?[c];
    if (v is List) return v.map((e) => e.toString()).toList();
    return [];
  }

  Widget _column(List<String> items, ValueChanged<String> onTap,
      {String selected = ''}) {
    final cs = context.cs;
    if (items.isEmpty) {
      return Center(
          child: Text('请先选择${selected == _province && _province.isNotEmpty ? '区县' : '省份'}',
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)));
    }
    return ListView.builder(
      itemCount: items.length,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemBuilder: (_, i) {
        final it = items[i];
        final isSel = it == selected;
        return InkWell(
          onTap: () => onTap(it),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            color: isSel ? AppTheme.primary.withValues(alpha: 0.08) : null,
            child: Row(children: [
              Expanded(
                child: Text(it,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 14,
                        color: isSel ? AppTheme.primary : cs.onSurface,
                        fontWeight: isSel ? FontWeight.w600 : FontWeight.w400)),
              ),
              if (it is String && _hasChildren(it))
                Icon(Icons.chevron_right, size: 18, color: cs.onSurfaceVariant),
            ]),
          ),
        );
      },
    );
  }

  bool _hasChildren(String item) {
    if (_provinceList.contains(item)) return (_data[item] as Map?)?.isNotEmpty == true;
    if (_cityList.contains(item)) return _districtListOf(_province, item).isNotEmpty;
    return false;
  }
}
