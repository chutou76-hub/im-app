import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../l10n/app_locale.dart';
import '../theme/app_theme.dart';

/// 城市选择弹层（2026-11-10 朋友圈「同城」tab 手动切换城市）：
/// 数据复用 assets/region/pca.json（{省: {市: [区...]}}，Gitee
/// modood/Administrative-divisions-of-China，与发布弹层省市区选择器同源），
/// 只做「省 → 市」两级列表（选市即确认，不进区县）。
/// 返回市全名（如「衡阳市」「北京市」——直辖市取省名，与发布位置高德逆地理
/// 口径一致：直辖市 city 回退省名）；取消返回 null。
/// [currentCity] 非空时打开弹层自动定位到该城市所在省（提升手动切换体验）。
/// [locate] 2026-11-13 需求：顶部「定位城市」行——打开弹层即异步定位
/// （GPS→IP 两级由调用方封装），成功显示「📍 城市」可一键选中，
/// 定位中显示转圈，失败显示「无法获取定位」灰字（不再无声）。
/// 2026-11-13 失败原因细分：回调返回 (城市, 失败原因提示) 记录，失败时
/// 原因文案追加在「无法获取定位」之后（未配Key/无GPS信号/权限未授权等）。
class CityPickerSheet {
  CityPickerSheet._();

  /// 打开选择器；返回市全名字符串或 null（取消）
  static Future<String?> show(BuildContext context,
      {String currentCity = '',
      Future<(String?, String?)> Function()? locate}) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CityPicker(currentCity: currentCity, locate: locate),
    );
  }
}

class _CityPicker extends StatefulWidget {
  /// 当前同城城市（市全名），用于打开时预选中其所在省
  final String currentCity;

  /// 异步定位回调（GPS→IP 兜底封装在调用方）；null = 不显示定位行。
  /// 返回 (城市, 失败原因提示)：城市非空=成功；否则失败原因显示在定位行
  final Future<(String?, String?)> Function()? locate;
  const _CityPicker({this.currentCity = '', this.locate});

  @override
  State<_CityPicker> createState() => _CityPickerState();
}

class _CityPickerState extends State<_CityPicker> {
  Map<String, dynamic> _data = {};
  bool _loading = true;
  String _province = '';

  // 顶部定位城市行：0=定位中 1=成功 2=失败
  int _locState = 0;
  String _locatedCity = '';
  // 2026-11-13 失败原因细分：具体原因文案（notConfigured/noFix 等）
  String _locFailHint = '';

  @override
  void initState() {
    super.initState();
    _load();
    _startLocate();
  }

  Future<void> _startLocate() async {
    final locate = widget.locate;
    if (locate == null) {
      if (mounted) setState(() => _locState = 2);
      return;
    }
    try {
      final (city, hint) = await locate();
      if (!mounted) return;
      setState(() {
        if (city != null && city.isNotEmpty) {
          _locatedCity = city;
          _locState = 1;
        } else {
          _locFailHint = hint ?? '';
          _locState = 2;
        }
      });
    } catch (_) {
      if (mounted) setState(() => _locState = 2);
    }
  }

  List<String> get _provinceList => _data.keys.toList();
  List<String> get _cityList =>
      _province.isEmpty
          ? []
          : ((_data[_province] as Map?)?.keys.toList().cast<String>() ?? []);

  Future<void> _load() async {
    try {
      final raw = await rootBundle.loadString('assets/region/pca.json');
      final d = json.decode(raw) as Map<String, dynamic>;
      // 直辖市规整（2026-11-10 QA Round 1 修复）：pca.json 直辖市（北京/天津/
      // 上海/重庆，省 key 以「市」结尾）的市层级 key 是占位符「市辖区」（重庆
      // 还有「县」），直接弹出会返回「市辖区」→ 服务端 (city=? OR province=?)
      // 匹配不到发帖侧高德口径（直辖市 city 回退省名）→ 同城列表错空、
      // tab 文案错误。这里把直辖市市列表替换为省名本身（如「北京市」），
      // 选城返回值 / currentCity 预选 / _cityLabel 全链路自然一致；
      // 不改 pca.json 业务数据文件本身。
      final norm = <String, dynamic>{};
      d.forEach((p, cities) {
        if (p.endsWith('市')) {
          norm[p] = <String, dynamic>{p: <dynamic>[]};
        } else {
          norm[p] = cities;
        }
      });
      // 预定位当前城市所在省：在数据里反查哪个省的市列表包含当前城市
      // （直辖市已规整为省名 →「北京市」可正确反查到北京市）
      String prov = '';
      final cur = widget.currentCity;
      if (cur.isNotEmpty) {
        norm.forEach((p, cities) {
          if (prov.isEmpty && cities is Map && cities.containsKey(cur)) {
            prov = p;
          }
        });
      }
      if (mounted) {
        setState(() {
          _data = norm;
          _province = prov;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final t = AppLocalizations.of(context).t;
    return SafeArea(
      child: Container(
        height: MediaQuery.of(context).size.height * 0.5,
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Column(
          children: [
            // 标题栏（四语 l10n）
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              decoration: BoxDecoration(
                border: Border(
                    bottom: BorderSide(
                        color: cs.outlineVariant.withValues(alpha: 0.4))),
              ),
              child: Row(children: [
                Expanded(
                  child: Text(
                    // 已选省时面包屑「省 · 选择城市」，否则仅标题
                    _province.isEmpty
                        ? t('momentsPickCity')
                        : '$_province · ${t('momentsPickCity')}',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(t('cancel')),
                ),
              ]),
            ),
            // 顶部定位城市行（2026-11-13 需求：先显示定位到的城市，再手动切换）
            if (widget.locate != null) _buildLocateRow(t, cs),
            if (_loading)
              const Expanded(
                  child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2)))
            else if (_data.isEmpty)
              Expanded(
                child: Center(
                  child: Text(t('momentsPickCity'),
                      style: TextStyle(
                          fontSize: 13, color: cs.onSurfaceVariant)),
                ),
              )
            else ...[
              // 左列：省；右列：当前省下的市（选市即确认）
              Expanded(child: _column(_provinceList, _onPickProvince,
                  selected: _province)),
              Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.4)),
              Expanded(
                child: _cityList.isEmpty
                    ? Center(
                        child: Text(t('momentsPickCity'),
                            style: TextStyle(
                                fontSize: 13, color: cs.onSurfaceVariant)))
                    : _column(_cityList, _onPickCity),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _onPickProvince(String p) => setState(() => _province = p);

  /// 顶部定位城市行：定位中转圈 / 成功「📍 城市 + 点击使用」可一键选中 /
  /// 失败灰字「无法获取定位」（与省市区列表间以细分割线隔开）
  Widget _buildLocateRow(String Function(String) t, ColorScheme cs) {
    final Widget content;
    if (_locState == 0) {
      content = Row(children: [
        const SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(strokeWidth: 1.6)),
        const SizedBox(width: 8),
        Text(t('locLocating'),
            style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
      ]);
    } else if (_locState == 1) {
      content = Row(children: [
        const Icon(Icons.location_on, size: 16, color: AppTheme.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(_locatedCity,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.primary)),
        ),
        Text(t('locTapToUse'),
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      ]);
    } else {
      // 2026-11-13 失败原因细分：原因文案追加在「无法获取定位」之后
      final failText = _locFailHint.isEmpty
          ? t('locLocateFailed')
          : '${t('locLocateFailed')}·$_locFailHint';
      content = Row(children: [
        Icon(Icons.location_off, size: 15, color: cs.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(failText,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12.5, color: cs.onSurfaceVariant)),
        ),
      ]);
    }
    return Container(
      decoration: BoxDecoration(
          border: Border(
              bottom:
                  BorderSide(color: cs.outlineVariant.withValues(alpha: 0.4)))),
      child: InkWell(
        // 成功=一键选中；失败=点击重试（模拟器设置模拟位置/开权限后再试）
        onTap: _locState == 1
            ? () => Navigator.pop(context, _locatedCity)
            : (_locState == 2
                ? () {
                    setState(() => _locState = 0);
                    _startLocate();
                  }
                : null),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: content,
        ),
      ),
    );
  }


  /// 选市即确认：返回市全名（直辖市即省名，如「北京市」）
  void _onPickCity(String c) => Navigator.pop(context, c);

  Widget _column(List<String> items, ValueChanged<String> onTap,
      {String selected = ''}) {
    final cs = context.cs;
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
                        fontWeight:
                            isSel ? FontWeight.w600 : FontWeight.w400)),
              ),
              // 省行有下级（市列表）才显示箭头；市行点击即确认不显示
              if (_provinceList.contains(it) &&
                  (_data[it] as Map?)?.isNotEmpty == true)
                Icon(Icons.chevron_right, size: 18, color: cs.onSurfaceVariant),
            ]),
          ),
        );
      },
    );
  }
}
