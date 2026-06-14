class Movie {
  final String id;
  final String name;
  final String streamIcon;
  final String categoryId;
  final String containerExtension;
  final String plot;
  final String cast;
  final String genre;
  final String releaseDate;
  final String rating;

  Movie({
    required this.id,
    required this.name,
    required this.streamIcon,
    required this.categoryId,
    required this.containerExtension,
    required this.plot,
    required this.cast,
    required this.genre,
    required this.releaseDate,
    required this.rating,
  });

  factory Movie.fromJson(Map<String, dynamic> json) {
    // get_vod_streams → campos planos en json
    // get_vod_info    → info en json['info'], metadatos en json['movie_data']
    final info = json['info'] ?? json['movie_data'] ?? json;
    return Movie(
      id: (json['stream_id'] ?? json['vod_id'] ?? json['id'])?.toString() ?? '',
      name: (json['name'] ?? json['title'])?.toString() ?? '',
      streamIcon: (json['stream_icon'] ?? json['cover'] ?? info['movie_image'])
                    ?.toString() ?? '',
      categoryId: json['category_id']?.toString() ?? '',
      containerExtension: (json['container_extension'] ?? info['container_extension'])
                            ?.toString() ?? 'mp4',
      plot: info['plot']?.toString() ?? '',
      cast: info['cast']?.toString() ?? '',
      genre: info['genre']?.toString() ?? '',
      releaseDate: (info['releaseDate'] ?? info['release_date'] ?? info['year'])
                    ?.toString() ?? '',
      rating: (info['rating'] ?? info['rating_5based'])?.toString() ?? '',
    );
  }

  String streamUrl(String baseUrl, String username, String password) {
    return '$baseUrl/movie/$username/$password/$id.$containerExtension';
  }
}
