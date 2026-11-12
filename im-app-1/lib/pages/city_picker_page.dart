import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../l10n/app_locale.dart';
import '../theme/app_theme.dart';
import '../widgets/app_back_button.dart';

/// 城市选择全屏页（2026-11-12 替换原底部弹层 CityPickerSheet）。
///
/// 背景：原弹层只有屏高 50%，省列表与市列表**上下堆叠**，一打开看到
/// 「北京市 / 天津市 / 河北省 … 北京市」——上半屏 31 个省、下半屏是所选省的市，
/// 直辖市时上下都叫「北京市」，观感像列表重复；且没有搜索，34 个省只能靠滚。
///
/// 新形态（整屏）：
///   1. 顶部搜索框：输城市名即时过滤（支持按省名搜，如「广东」列出全省市）；
///   2. 「📍 定位城市」行：GPS→IP 两级由调用方封装（[locate]），可一键使用，
///      失败时显示原因并可点重试；
///   3. 热门城市九宫格：常用 12 城一步直达；
///   4. 全部城市：按省级拼音首字母 A-Z 分组，右侧字母索引条可点可拖；
///   5. 点省 → 进二级市列表（同一页风格），选市即确认返回。
///
/// 数据源仍是 `assets/region/pca.json`（与发布页省市区选择器同源），
/// 口径与发布位置的高德逆地理一致：**直辖市市级取省名**（北京市/上海市/
/// 天津市/重庆市），保证同城列表按 `city=? OR province=?` 能匹配到。
///
/// 返回市全名（如「衡阳市」「北京市」），取消返回 null。
class CityPickerPage extends StatefulWidget {
  /// 当前同城城市（市全名），用于高亮 + 打开时自动滚到其所在省
  final String currentCity;

  /// 异步定位回调（GPS→IP 兜底封装在调用方）；null = 不显示定位块。
  /// 返回 (城市, 失败原因提示)：城市非空=成功；否则原因显示在定位块
  final Future<(String?, String?)> Function()? locate;

  const CityPickerPage({super.key, this.currentCity = '', this.locate});

  /// 打开页面；返回市全名字符串或 null（取消）
  static Future<String?> show(BuildContext context,
      {String currentCity = '', Future<(String?, String?)> Function()? locate}) {
    return Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) =>
          CityPickerPage(currentCity: currentCity, locate: locate),
      settings: const RouteSettings(name: '/city-picker'),
    ));
  }

  @override
  State<CityPickerPage> createState() => _CityPickerPageState();
}

/// 省级行政区 → 拼音首字母（31 个，A-Z 索引分组用；pca.json 无拼音字段，
/// 这里静态维护，新增省级行政区时需同步补充，缺省归入 # 组）
const Map<String, String> _kProvinceInitial = {
  '北京市': 'B',
  '天津市': 'T',
  '河北省': 'H',
  '山西省': 'S',
  '内蒙古自治区': 'N',
  '辽宁省': 'L',
  '吉林省': 'J',
  '黑龙江省': 'H',
  '上海市': 'S',
  '江苏省': 'J',
  '浙江省': 'Z',
  '安徽省': 'A',
  '福建省': 'F',
  '江西省': 'J',
  '山东省': 'S',
  '河南省': 'H',
  '湖北省': 'H',
  '湖南省': 'H',
  '广东省': 'G',
  '广西壮族自治区': 'G',
  '海南省': 'H',
  '重庆市': 'C',
  '四川省': 'S',
  '贵州省': 'G',
  '云南省': 'Y',
  '西藏自治区': 'X',
  '陕西省': 'S',
  '甘肃省': 'G',
  '青海省': 'Q',
  '宁夏回族自治区': 'N',
  '新疆维吾尔自治区': 'X',
};

/// 热门城市（直辖市写市全名，与返回口径一致；不在 pca.json 里的会被忽略）
const List<String> _kHotCities = [
  '北京市',
  '上海市',
  '广州市',
  '深圳市',
  '杭州市',
  '成都市',
  '重庆市',
  '武汉市',
  '西安市',
  '南京市',
  '天津市',
  '苏州市',
];

// ── 行高（像素）：固定高度才能精确算出字母分组的滚动偏移，供索引条跳转 ──
const double _hLocBlock = 74; // 定位块（标题 + 一行）
const double _hSectionHeader = 44; // 「热门城市」「全部城市」
const double _hLetterHeader = 28; // A / B / C 分组小标题
const double _hProvinceRow = 52; // 省行
const double _hHotChip = 34; // 热门城市胶囊
const double _hotChipGap = 8;
const double _indexBarPad = 6; // A-Z 索引条上下留白

/// 搜索结果项
class _CityHit {
  final String city;
  final String province;
  const _CityHit(this.city, this.province);
}

/// 浏览态的一行（固定高度，便于偏移计算）
class _Row {
  /// 0=定位块 1=热门标题 2=热门网格 3=全部城市标题 4=字母小标题 5=省行
  final int type;
  final String text;
  final double h;
  const _Row(this.type, this.text, this.h);
}

class _CityPickerPageState extends State<CityPickerPage> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  /// 省 → 市列表（直辖市已规整为「市名 = 省名」）
  Map<String, List<String>> _data = {};
  bool _loading = true;

  /// 当前城市所在省（用于高亮 + 自动定位滚动）
  String _province = '';

  String _query = '';
  List<_CityHit> _hits = const [];

  List<String> _letters = const [];
  List<_Row> _rows = const [];
  Map<String, double> _offsetByLetter = const {};

  // 定位块状态：0=定位中 1=成功 2=失败
  int _locState = 0;
  String _locatedCity = '';
  String _locFailHint = '';

  @override
  void initState() {
    super.initState();
    _load();
    _startLocate();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _startLocate() async {
    final locate = widget.locate;
    if (locate == null) return;
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

  Future<void> _load() async {
    Map<String, List<String>> norm = {};
    try {
      final raw = await rootBundle.loadString('assets/region/pca.json');
      final d = json.decode(raw) as Map<String, dynamic>;
      // 直辖市规整：pca.json 直辖市（省 key 以「市」结尾）下挂的是「市辖区」
      // 占位，直接弹出会返回「市辖区」→ 服务端 city=? 匹配不到发帖侧高德
      // 口径（直辖市 city 回退省名）。这里市级直接取省名本身。
      d.forEach((p, cities) {
        if (p.endsWith('市')) {
          norm[p] = <String>[p];
        } else if (cities is Map) {
          norm[p] = cities.keys.map((e) => e.toString()).toList();
        }
      });
    } catch (_) {
      norm = {};
    }
    if (!mounted) return;
    setState(() {
      _data = norm;
      _loading = false;
      // 反查当前城市所在省（直辖市「北京市」可正确命中）
      final cur = widget.currentCity;
      for (final e in norm.entries) {
        if (e.value.contains(cur)) {
          _province = e.key;
          break;
        }
      }
      _buildRows();
    });
    // 打开即滚到当前城市所在的字母分组（首帧布局完成后再滚）
    if (_province.isNotEmpty) {
      final letter = _kProvinceInitial[_province] ?? '#';
      final off = _offsetByLetter[letter];
      if (off != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) _scroll.jumpTo(off.clamp(0, _maxScroll));
        });
      }
    }
  }

  double get _maxScroll =>
      _scroll.hasClients ? _scroll.position.maxScrollExtent : 0;

  /// 热门城市里真实存在于数据的（防止数据源变化后出现死链）
  List<String> get _hotCities {
    final all = <String>{for (final l in _data.values) ...l};
    return _kHotCities.where(all.contains).toList();
  }

  void _buildRows() {
    final rows = <_Row>[];
    double y = 0;
    final offsetByLetter = <String, double>{};

    if (widget.locate != null) {
      rows.add(const _Row(0, '', _hLocBlock));
      y += _hLocBlock;
    }
    final hot = _hotCities;
    if (hot.isNotEmpty) {
      rows.add(const _Row(1, '', _hSectionHeader));
      y += _hSectionHeader;
      final gridH = _hotGridHeight(hot.length);
      rows.add(_Row(2, '', gridH));
      y += gridH;
    }
    rows.add(const _Row(3, '', _hSectionHeader));
    y += _hSectionHeader;

    // 按首字母分组（组内保留 pca.json 原顺序）
    final groups = <String, List<String>>{};
    _data.forEach((p, _) {
      final l = _kProvinceInitial[p] ?? '#';
      (groups[l] ??= <String>[]).add(p);
    });
    final letters = groups.keys.toList()..sort();
    for (final l in letters) {
      offsetByLetter[l] = y;
      rows.add(_Row(4, l, _hLetterHeader));
      y += _hLetterHeader;
      for (final p in groups[l]!) {
        rows.add(_Row(5, p, _hProvinceRow));
        y += _hProvinceRow;
      }
    }
    _rows = rows;
    _letters = letters;
    _offsetByLetter = offsetByLetter;
  }

  /// 热门网格高度：4 列胶囊 + 行间距 + 上下留白
  double _hotGridHeight(int count) {
    final rows = (count / 4).ceil();
    return rows * _hHotChip +
        (rows - 1) * _hotChipGap +
        12; // 上下各 6 的留白
  }

  void _onQueryChanged(String q) {
    final s = q.trim().toLowerCase();
    if (s.isEmpty) {
      setState(() {
        _query = '';
        _hits = const [];
      });
      return;
    }
    final hits = <_CityHit>[];
    _data.forEach((p, cities) {
      final pMatch = p.toLowerCase().contains(s);
      for (final c in cities) {
        final cLow = c.toLowerCase();
        if (cLow.contains(s) || pMatch) hits.add(_CityHit(c, p));
      }
    });
    // 排序：市名前缀 > 市名包含 > 仅省名命中（组内保持原顺序）
    int score(_CityHit h) {
      final c = h.city.toLowerCase();
      if (c.startsWith(s)) return 0;
      if (c.contains(s)) return 1;
      return 2;
    }

    final indexed = <(int, int, _CityHit)>[];
    for (var i = 0; i < hits.length; i++) {
      indexed.add((score(hits[i]), i, hits[i]));
    }
    indexed.sort((a, b) {
      final c = a.$1.compareTo(b.$1);
      return c != 0 ? c : a.$2.compareTo(b.$2);
    });
    setState(() {
      _query = s;
      _hits = [for (final e in indexed.take(60)) e.$3];
    });
  }

  void _pick(String city) => Navigator.of(context).pop(city);

  Future<void> _openProvince(String p) async {
    final cities = _data[p];
    if (cities == null || cities.isEmpty) return;
    // 直辖市（省市级同名，列表只有一项）：不必再进二级页，直接选中
    if (cities.length == 1) {
      _pick(cities.first);
      return;
    }
    final picked = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => _ProvinceCityPage(
        province: p,
        cities: cities,
        current: widget.currentCity,
      ),
    ));
    if (picked != null && picked.isNotEmpty && mounted) {
      Navigator.of(context).pop(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    return Scaffold(
      appBar: AppBar(
        leading: const AppBackButton(),
        title: Text(t('momentsPickCity')),
        centerTitle: true,
      ),
      body: Column(
        children: [
          _buildSearchField(t),
          Expanded(
            child: _loading
                ? const Center(
                    child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2)))
                : (_query.isEmpty ? _buildBrowse(t) : _buildResults(t)),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchField(String Function(String) t) {
    final cs = context.cs;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: SizedBox(
        height: 40,
        child: TextField(
          controller: _search,
          focusNode: _searchFocus,
          onChanged: _onQueryChanged,
          textInputAction: TextInputAction.search,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 11),
            hintText: t('citySearchHint'),
            hintStyle: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
            prefixIcon: Icon(Icons.search,
                size: 19, color: cs.onSurfaceVariant),
            prefixIconConstraints:
                const BoxConstraints(minWidth: 38, minHeight: 38),
            suffixIcon: _query.isEmpty
                ? null
                : GestureDetector(
                    onTap: () {
                      _search.clear();
                      _onQueryChanged('');
                    },
                    child: Icon(Icons.cancel,
                        size: 17, color: cs.onSurfaceVariant),
                  ),
            suffixIconConstraints:
                const BoxConstraints(minWidth: 34, minHeight: 34),
            filled: true,
            fillColor: dark ? const Color(0xFF2C2C2E) : const Color(0xFFF2F2F7),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
    );
  }

  /// 搜索态：扁平结果列表
  Widget _buildResults(String Function(String) t) {
    final cs = context.cs;
    if (_hits.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search_off, size: 34, color: cs.onSurfaceVariant),
              const SizedBox(height: 10),
              Text(t('cityNoResult'),
                  style: TextStyle(fontSize: 14, color: cs.onSurface)),
              const SizedBox(height: 4),
              Text(t('cityNoResultHint'),
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: _hits.length,
      separatorBuilder: (_, __) => Divider(
          height: 1,
          indent: 16,
          color: cs.outlineVariant.withValues(alpha: 0.35)),
      itemBuilder: (_, i) {
        final h = _hits[i];
        final isCur = h.city == widget.currentCity;
        return InkWell(
          onTap: () {
            _searchFocus.unfocus();
            _pick(h.city);
          },
          child: Container(
            height: _hProvinceRow,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Expanded(
                child: Text(_shortCity(h.city),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight:
                            isCur ? FontWeight.w600 : FontWeight.w400,
                        color: isCur ? AppTheme.primary : cs.onSurface)),
              ),
              if (h.province != h.city)
                Text(h.province,
                    style:
                        TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              if (isCur) _currentTag(t, cs),
            ]),
          ),
        );
      },
    );
  }

  /// 浏览态：定位块 + 热门 + 全部城市（A-Z）+ 右侧索引条
  Widget _buildBrowse(String Function(String) t) {
    return Stack(
      children: [
        ListView.builder(
          controller: _scroll,
          // 右侧留出索引条宽度，避免省行的「>」被字母条压住
          padding: const EdgeInsets.only(right: 18),
          itemCount: _rows.length,
          itemBuilder: (_, i) {
            final r = _rows[i];
            switch (r.type) {
              case 0:
                return _buildLocateBlock(t);
              case 1:
                return _sectionHeader(t('cityHot'));
              case 2:
                return _buildHotGrid(t);
              case 3:
                return _sectionHeader(t('cityAll'));
              case 4:
                return Container(
                  height: _hLetterHeader,
                  padding: const EdgeInsets.only(left: 16),
                  alignment: Alignment.centerLeft,
                  color: context.cs.surfaceContainerHighest
                      .withValues(alpha: 0.35),
                  child: Text(r.text,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: context.cs.onSurfaceVariant)),
                );
              default:
                return _provinceRow(r.text, t);
            }
          },
        ),
        if (_letters.isNotEmpty) _buildIndexBar(),
      ],
    );
  }

  Widget _sectionHeader(String text) => Container(
        height: _hSectionHeader,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        alignment: Alignment.centerLeft,
        child: Text(text,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.cs.onSurfaceVariant)),
      );

  /// 定位块：定位中转圈 / 成功「📍 城市 · 点击使用」/ 失败灰色原因（点击重试）
  Widget _buildLocateBlock(String Function(String) t) {
    final cs = context.cs;
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
        const Icon(Icons.location_on, size: 17, color: AppTheme.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(_shortCity(_locatedCity),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.primary)),
        ),
        Text(t('locTapToUse'),
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        Icon(Icons.chevron_right, size: 18, color: cs.onSurfaceVariant),
      ]);
    } else {
      final failText = _locFailHint.isEmpty
          ? t('locLocateFailed')
          : '${t('locLocateFailed')}·$_locFailHint';
      content = Row(children: [
        Icon(Icons.location_off, size: 16, color: cs.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(failText,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
        ),
        Text(t('locTapToUse'),
            style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant)),
      ]);
    }
    return Container(
      height: _hLocBlock,
      decoration: BoxDecoration(
          border: Border(
              bottom: BorderSide(
                  color: cs.outlineVariant.withValues(alpha: 0.4)))),
      child: InkWell(
        // 成功=一键使用；失败=点击重新定位
        onTap: _locState == 1
            ? () => _pick(_locatedCity)
            : (_locState == 2
                ? () {
                    setState(() => _locState = 0);
                    _startLocate();
                  }
                : null),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: content,
        ),
      ),
    );
  }

  Widget _buildHotGrid(String Function(String) t) {
    final hot = _hotCities;
    return SizedBox(
      height: _hotGridHeight(hot.length),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: LayoutBuilder(builder: (ctx, box) {
          const gap = _hotChipGap;
          final w = (box.maxWidth - gap * 3) / 4;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final c in hot)
                SizedBox(
                  width: w,
                  height: _hHotChip,
                  child: _hotChip(c, t),
                ),
            ],
          );
        }),
      ),
    );
  }

  Widget _hotChip(String city, String Function(String) t) {
    final cs = context.cs;
    final cur = city == widget.currentCity;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _pick(city),
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: cur
              ? AppTheme.primary.withValues(alpha: 0.1)
              : cs.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(_shortCity(city),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 13.5,
                fontWeight: cur ? FontWeight.w600 : FontWeight.w500,
                color: cur ? AppTheme.primary : cs.onSurface)),
      ),
    );
  }

  Widget _provinceRow(String p, String Function(String) t) {
    final cs = context.cs;
    // 高亮=当前城市所在省；「当前」标签只在直辖市（省名即城市名）显示，
    // 否则挂在「广东省」这种省行上会误导（当前城市是广州市，不是广东省）
    final isCurProv = p == _province;
    final isCurCity = p == widget.currentCity;
    return InkWell(
      onTap: () => _openProvince(p),
      child: Container(
        height: _hProvinceRow,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          Expanded(
            child: Text(p,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: isCurProv ? FontWeight.w600 : FontWeight.w400,
                    color: isCurProv ? AppTheme.primary : cs.onSurface)),
          ),
          if (isCurCity) _currentTag(t, cs),
          Icon(Icons.chevron_right, size: 18, color: cs.onSurfaceVariant),
        ]),
      ),
    );
  }

  Widget _currentTag(String Function(String) t, ColorScheme cs) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(t('cityCurrentTag'),
          style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: AppTheme.primary)),
    );
  }

  /// 右侧 A-Z 索引条：点/拖跳转对应分组（偏移由固定行高预算，无需测量）
  Widget _buildIndexBar() {
    const itemH = 16.0;
    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      child: Center(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (d) => _jumpByDy(d.localPosition.dy, itemH),
          onVerticalDragUpdate: (d) => _jumpByDy(d.localPosition.dy, itemH),
          child: Container(
            width: 24,
            padding: const EdgeInsets.symmetric(vertical: _indexBarPad),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final l in _letters)
                  SizedBox(
                    width: 24,
                    height: itemH,
                    child: Center(
                      child: Text(l,
                          style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: l ==
                                      (_kProvinceInitial[_province] ?? '')
                                  ? AppTheme.primary
                                  : context.cs.onSurfaceVariant)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _jumpByDy(double dy, double itemH) {
    if (_letters.isEmpty) return;
    // 索引条容器有 6px 上留白，先扣掉再算命中行（否则整体偏一行）
    final i = ((dy - _indexBarPad) / itemH).floor().clamp(0, _letters.length - 1);
    final off = _offsetByLetter[_letters[i]];
    if (off == null || !_scroll.hasClients) return;
    _scroll.jumpTo(off.clamp(0, _maxScroll));
  }

  /// 展示用短名：「北京市」→「北京」，「广西壮族自治区」保留全名
  static String _shortCity(String c) =>
      c.length > 2 && c.endsWith('市') ? c.substring(0, c.length - 1) : c;
}

/// 二级页：某省下的市列表（选市即确认，把结果交回上一级统一 pop）
class _ProvinceCityPage extends StatelessWidget {
  final String province;
  final List<String> cities;
  final String current;

  const _ProvinceCityPage(
      {required this.province, required this.cities, this.current = ''});

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final t = AppLocalizations.of(context).t;
    return Scaffold(
      appBar: AppBar(
        leading: const AppBackButton(),
        title: Text(province),
        centerTitle: true,
      ),
      body: ListView.separated(
        itemCount: cities.length,
        separatorBuilder: (_, __) => Divider(
            height: 1,
            indent: 16,
            color: cs.outlineVariant.withValues(alpha: 0.35)),
        itemBuilder: (_, i) {
          final c = cities[i];
          final cur = c == current;
          return InkWell(
            onTap: () => Navigator.of(context).pop(c),
            child: Container(
              height: _hProvinceRow,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                Expanded(
                  child: Text(c,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: cur ? FontWeight.w600 : FontWeight.w400,
                          color: cur ? AppTheme.primary : cs.onSurface)),
                ),
                if (cur)
                  Container(
                    margin: const EdgeInsets.only(left: 6),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(t('cityCurrentTag'),
                        style: const TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.primary)),
                  ),
              ]),
            ),
          );
        },
      ),
    );
  }
}
