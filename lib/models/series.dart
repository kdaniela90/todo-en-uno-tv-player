class Series {
  final String id;
  final String name;
  final String cover;
  final String categoryId;

  Series({required this.id, required this.name, required this.cover, required this.categoryId});

  factory Series.fromJson(Map<String, dynamic> j) => Series(
    id: j['series_id']?.toString() ?? '',
    name: j['name'] ?? '',
    cover: j['cover'] ?? '',
    categoryId: j['category_id']?.toString() ?? '',
  );
}
