class Category {
  final String id;
  final String name;

  Category({required this.id, required this.name});

  factory Category.fromJson(Map<String, dynamic> json) {
    return Category(
      id: json['category_id']?.toString() ?? '',
      name: json['category_name']?.toString() ?? '',
    );
  }
}
