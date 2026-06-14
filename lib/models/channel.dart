class Channel {
  final String id;
  final String name;
  final String streamType;
  final String streamIcon;
  final String categoryId;
  final String epgChannelId;

  Channel({
    required this.id,
    required this.name,
    required this.streamType,
    required this.streamIcon,
    required this.categoryId,
    required this.epgChannelId,
  });

  factory Channel.fromJson(Map<String, dynamic> json) {
    return Channel(
      id: json['stream_id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      streamType: json['stream_type']?.toString() ?? 'live',
      streamIcon: json['stream_icon']?.toString() ?? '',
      categoryId: json['category_id']?.toString() ?? '',
      epgChannelId: json['epg_channel_id']?.toString() ?? '',
    );
  }

  String streamUrl(String baseUrl, String username, String password) {
    return '$baseUrl/live/$username/$password/$id.ts';
  }
}
