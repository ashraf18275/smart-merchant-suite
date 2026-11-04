/// Supported ways a payment can actually be settled.
/// Credit is deliberately not a payment method: it remains an unpaid ledger balance.
abstract final class PaymentMethod {
  static const cash = 'cash';
  static const card = 'card';
  static const bankTransfer = 'bank_transfer';
  static const wallet = 'wallet';

  static const all = <String>{cash, card, bankTransfer, wallet};
  static const labels = <String, String>{
    cash: 'نقدي',
    card: 'بطاقة',
    bankTransfer: 'تحويل بنكي',
    wallet: 'محفظة إلكترونية',
  };

  static bool isValid(String value) => all.contains(value);
}
