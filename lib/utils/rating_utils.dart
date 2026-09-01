import '../models/app_models.dart';

String formatRating(double rating) {
  if (!rating.isFinite || rating < 0) {
    return '0.0';
  }
  final truncated = (rating * 10).floor() / 10;
  return truncated.toStringAsFixed(1);
}

int compareSalonsByRating(Salon left, Salon right) {
  final ratingOrder = right.rating.compareTo(left.rating);
  if (ratingOrder != 0) {
    return ratingOrder;
  }
  final reviewCountOrder = right.reviewCount.compareTo(left.reviewCount);
  if (reviewCountOrder != 0) {
    return reviewCountOrder;
  }
  return 0;
}
