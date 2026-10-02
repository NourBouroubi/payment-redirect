import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dart_appwrite/dart_appwrite.dart';
import 'package:dart_appwrite/enums.dart' show ExecutionMethod;

Future<dynamic> main(final context) async {
  final method = (context.req.method ?? 'GET').toString().toUpperCase();
  context.log('Request method: $method');

  // POST from Paddle (card payments on store.ah-mar.app)
  if (method == 'POST' &&
      (context.req.headers['paddle-signature'] ?? '').toString().isNotEmpty) {
    return _handlePaddle(context);
  }

  // POST = Chargily webhook callback
  if (method == 'POST') {
    return _handleWebhook(context);
  }

  // GET = Browser redirect (after payment)
  return _handleRedirect(context);
}

// ══════════════════════════════════════════════════════════
// WEBHOOK HANDLER (POST from Chargily)
// ══════════════════════════════════════════════════════════
Future<dynamic> _handleWebhook(final context) async {
  try {
    context.log('=== Chargily Webhook Handler ===');

    final chargilySecret = Platform.environment['CHARGILY_SECRET_KEY'] ?? '';
    final chargilySignature = context.req.headers['signature'] ?? '';

    context.log('Secret present: ${chargilySecret.isNotEmpty}');
    context.log('Signature present: ${chargilySignature.isNotEmpty}');

    if (chargilySecret.isEmpty || chargilySignature.isEmpty) {
      context.error('Missing secret key or signature header.');
      return context.res.json({'error': 'Configuration error'}, 400);
    }

    // Verify HMAC signature
    final key = utf8.encode(chargilySecret);
    final bytes = utf8.encode(context.req.bodyRaw);
    final hmacSha256 = Hmac(sha256, key);
    final digest = hmacSha256.convert(bytes);
    final generatedSignature = digest.toString();

    if (generatedSignature != chargilySignature) {
      context.error('INVALID SIGNATURE');
      context.error('Expected: $generatedSignature');
      context.error('Got: $chargilySignature');
      return context.res.text('INVALID SIGNATURE');
    }

    context.log('Signature verified successfully.');

    final apiKey = Platform.environment['APPWRITE_API_KEY'] ?? '';
    if (apiKey.isEmpty) {
      context.error('APPWRITE_API_KEY environment variable is not set');
      return context.res.text('FAILURE');
    }

    final client = Client()
        .setEndpoint(
            Platform.environment['APPWRITE_FUNCTION_API_ENDPOINT'] ??
                'https://backend.ah-mar.app/v1')
        .setProject(
            Platform.environment['APPWRITE_FUNCTION_PROJECT_ID'] ??
                '6966d5030009343737c1')
        .setKey(apiKey);

    final databases = Databases(client);

    final Map<String, dynamic> body = jsonDecode(context.req.bodyRaw);
    final String type = body['type']?.toString() ?? '';

    context.log('Event type: $type');

    if (type == 'checkout.paid') {
      final data = body['data'] as Map<String, dynamic>;
      final metadata = data['metadata'] as Map<String, dynamic>? ?? {};

      final String userId = metadata['user_id']?.toString() ?? '';
      final List<String> bookIds =
          List<String>.from(metadata['book_id'] ?? []);
      final double amount =
          (data['amount'] as num?)?.toDouble() ?? 0.0;

      context.log('Processing payment for user: $userId');
      context.log('Book IDs: $bookIds');
      context.log('Amount: $amount');

      if (userId.isEmpty || bookIds.isEmpty) {
        context.error('Missing user_id or book_id in metadata');
        return context.res.text('FAILURE');
      }

      // A paid gift belongs to its recipient, not to the payer. The gift
      // logic (and the Brevo/notify settings it needs) lives in the
      // "Chargily webhook" function, so hand it the untouched event with
      // Chargily's signature; it re-verifies before acting.
      final String giftId = metadata['gift_id']?.toString() ?? '';
      if (giftId.isNotEmpty) {
        return _forwardGift(context, chargilySignature, giftId);
      }

      // Chargily can deliver the same event more than once. The checkout id
      // becomes the transaction's document id, so a repeat is refused by the
      // database instead of being counted as a second sale.
      final String checkoutId = data['id']?.toString() ?? '';
      final String transactionId = _transactionId(checkoutId);

      final dbId = Platform.environment['DB_ID'] ?? '68b4bcf9001027235773';
      final transactionsTable =
          Platform.environment['DB_TRANSACTIONS'] ?? 'transactions_table';
      final userLibraryTable =
          Platform.environment['DB_USER_LIBRARY'] ?? 'user_library_table';

      // --- Refuse a payment below what the books cost ---
      final expected = await _expectedAmount(context, databases, dbId,
          bookIds, metadata['promo_code_id']?.toString() ?? '');
      if (expected != null && amount + 1 < expected) {
        context.error(
            'UNDERPAID: $userId paid $amount for $bookIds, expected $expected');
        try {
          await databases.createDocument(
            databaseId: dbId,
            collectionId: transactionsTable,
            documentId: transactionId,
            data: {
              'user_id': userId,
              'book_id': bookIds,
              'total_price': amount.round(),
              'status': 'underpaid',
            },
          );
        } catch (e) {
          context.error('Failed to record underpaid transaction: $e');
        }
        // SUCCESS so Chargily stops retrying; the books are not granted.
        return context.res.text('SUCCESS');
      }

      // --- Create Transaction Record ---
      try {
        await databases.createDocument(
          databaseId: dbId,
          collectionId: transactionsTable,
          documentId: transactionId,
          data: {
            'user_id': userId,
            'book_id': bookIds,
            // The column is an integer and Chargily sends 530.0, which the
            // structure check refuses outright. Rounded here rather than at
            // the parse above, so the logged amount stays what was received.
            'total_price': amount.round(),
            'status': 'completed',
          },
        );
        context.log('Transaction record created');
      } on AppwriteException catch (e) {
        if (e.code == 409) {
          context.log('Checkout $checkoutId already recorded; repeat delivery');
        } else {
          context.error('Failed to create transaction: $e');
        }
      } catch (e) {
        context.error('Failed to create transaction: $e');
      }

      // --- Update User Library ---
      // Read the CURRENT library from the database (not metadata snapshot)
      // to avoid overwriting books added since checkout was created
      try {
        final libraryDocs = await databases.listDocuments(
          databaseId: dbId,
          collectionId: userLibraryTable,
          queries: [
            Query.equal('user_id', userId),
            Query.limit(1),
            Query.select(['books.\$id']),
          ],
        );

        String docId;
        List<String> existingLibrary = [];

        if (libraryDocs.documents.isNotEmpty) {
          docId = libraryDocs.documents.first.$id;
          // Extract book IDs from relationship field
          final booksData = libraryDocs.documents.first.data['books'];
          if (booksData is List) {
            for (final item in booksData) {
              if (item is Map && item['\$id'] != null) {
                existingLibrary.add(item['\$id'].toString());
              } else if (item is String) {
                existingLibrary.add(item);
              }
            }
          }
        } else {
          docId = userId;
        }

        final List<String> newLibrary = List<String>.from(existingLibrary);
        for (final id in bookIds) {
          if (!newLibrary.contains(id)) {
            newLibrary.add(id);
          }
        }

        context.log('Library update: $existingLibrary -> $newLibrary');

        await databases.updateDocument(
          databaseId: dbId,
          collectionId: userLibraryTable,
          documentId: docId,
          data: {'books': newLibrary},
        );
        context.log('User library updated with ${newLibrary.length} books');
      } catch (e) {
        context.error('Failed to update library: $e');
        return context.res.text('FAILURE');
      }
    } else {
      context.log('Ignoring event type: $type');
    }

    return context.res.text('SUCCESS');
  } catch (e) {
    context.error('Webhook error: $e');
    return context.res.text('FAILURE');
  }
}

// ══════════════════════════════════════════════════════════
// REDIRECT HANDLER (GET from browser after payment)
// ══════════════════════════════════════════════════════════
Future<dynamic> _handleRedirect(final context) async {
  // Get status from query parameters
  final query = context.req.query as Map<String, dynamic>? ?? {};
  final status = query['status']?.toString() ?? 'cancel';

  context.log('Payment redirect called with status: $status');

  // Build deep link based on status
  final String deepLink;
  final String title;
  final String icon;
  final String color;

  switch (status) {
    case 'success':
      deepLink = 'melonbook://payment-success';
      title = 'Payment Successful!';
      icon = '✓';
      color = '#4CAF50';
      break;
    case 'failure':
      deepLink = 'melonbook://payment-failure';
      title = 'Payment Failed';
      icon = '✕';
      color = '#F44336';
      break;
    default:
      deepLink = 'melonbook://payment-cancel';
      title = 'Payment Cancelled';
      icon = '←';
      color = '#FF9800';
  }

  final html = '''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
    <title>$title</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 20px;
        }
        .card {
            background: white;
            border-radius: 24px;
            padding: 48px 32px;
            text-align: center;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            max-width: 340px;
            width: 100%;
        }
        .icon-circle {
            width: 80px;
            height: 80px;
            border-radius: 50%;
            background: $color;
            color: white;
            font-size: 40px;
            display: flex;
            align-items: center;
            justify-content: center;
            margin: 0 auto 24px;
            font-weight: bold;
        }
        h1 {
            color: #1a1a2e;
            font-size: 24px;
            margin-bottom: 12px;
        }
        p {
            color: #666;
            font-size: 16px;
            margin-bottom: 32px;
        }
        .loader {
            width: 40px;
            height: 40px;
            border: 4px solid #eee;
            border-top-color: $color;
            border-radius: 50%;
            animation: spin 1s linear infinite;
            margin: 0 auto 24px;
        }
        @keyframes spin {
            to { transform: rotate(360deg); }
        }
        .btn {
            display: inline-block;
            padding: 16px 48px;
            background: $color;
            color: white;
            text-decoration: none;
            border-radius: 30px;
            font-size: 16px;
            font-weight: 600;
            transition: transform 0.2s, box-shadow 0.2s;
        }
        .btn:active {
            transform: scale(0.98);
        }
        .hint {
            margin-top: 24px;
            font-size: 13px;
            color: #999;
        }
    </style>
</head>
<body>
    <div class="card">
        <div class="icon-circle">$icon</div>
        <h1>$title</h1>
        <p>Returning to Melon Book...</p>
        <div class="loader"></div>
        <a href="$deepLink" class="btn">Open App</a>
        <p class="hint">Tap the button if not redirected</p>
    </div>
    <script>
        // Immediate redirect attempt
        window.location.href = '$deepLink';
        
        // Retry after delays
        setTimeout(function() {
            window.location.href = '$deepLink';
        }, 300);
        
        setTimeout(function() {
            window.location.href = '$deepLink';
        }, 1000);
    </script>
</body>
</html>
''';

  return context.res.send(
    html,
    200,
    {'Content-Type': 'text/html; charset=utf-8'},
  );
}

/// What the books in [bookIds] cost, less the promo code the buyer used.
///
/// Chargily vouches for the amount it charged; the books' prices come from
/// the database. The checkout itself was built from a total the buyer's
/// device sent, so a paid amount below this is a tampered request.
///
/// The promo's usage counter and expiry are deliberately NOT checked: the app
/// increments the counter as soon as the checkout is created, before the
/// buyer has paid, so a legitimate last use would otherwise be refused here.
/// Returns null when the prices cannot be read, so a database hiccup never
/// costs a genuine buyer their book.
Future<int?> _expectedAmount(
  dynamic context,
  Databases databases,
  String dbId,
  List<String> bookIds,
  String promoId,
) async {
  try {
    final booksTable =
        Platform.environment['DB_STORE_BOOKS'] ?? 'store_books_table';
    Map<String, dynamic>? promo;
    if (promoId.isNotEmpty) {
      try {
        promo = (await databases.getDocument(
          databaseId: dbId,
          collectionId: Platform.environment['DB_PROMO_CODES'] ?? 'promo_codes',
          documentId: promoId,
        ))
            .data;
      } catch (e) {
        context.log('Promo $promoId not readable: $e');
      }
    }

    List<String> applicable = [];
    final raw = promo?['applicable_books'];
    if (raw is List) {
      applicable = raw.map((e) => e.toString()).toList();
    } else if (raw is String && raw.isNotEmpty && raw != '[]') {
      applicable = raw
          .replaceAll(RegExp(r'[\[\]"]'), '')
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }

    var total = 0;
    for (final id in bookIds.toSet()) {
      final book = await databases.getDocument(
        databaseId: dbId,
        collectionId: booksTable,
        documentId: id,
      );
      final price = (book.data['price'] as num?)?.round() ?? 0;
      var discount = 0;
      if (promo != null && (applicable.isEmpty || applicable.contains(id))) {
        final value = (promo['discount_value'] as num?)?.round() ?? 0;
        // Same rule as PromoCodeModel.calculateDiscount in the app.
        discount = (promo['discount_type'] ?? 'percentage') == 'percentage'
            ? (price * value / 100).round()
            : value.clamp(0, price);
      }
      total += price - discount;
    }
    return total;
  } catch (e) {
    context.error('Could not compute the expected amount: $e');
    return null;
  }
}

/// A document id derived from the Chargily checkout id, or a fresh one when
/// the event carries none. Appwrite ids allow a-z, 0-9, '.', '-', '_', at
/// most 36 characters, and must not start with a special character.
String _transactionId(String checkoutId) {
  final cleaned = checkoutId.toLowerCase().replaceAll(RegExp(r'[^a-z0-9._-]'), '');
  if (cleaned.isEmpty || !RegExp(r'^[a-z0-9]').hasMatch(cleaned)) {
    return ID.unique();
  }
  final id = 'chk_$cleaned';
  return id.length > 36 ? id.substring(0, 36) : id;
}

/// Passes a gift payment to the function that knows how to settle gifts.
///
/// Returns SUCCESS only when that function did, so Chargily retries anything
/// that did not land rather than the gift silently staying unpaid.
Future<dynamic> _forwardGift(
  final context,
  String signature,
  String giftId,
) async {
  final giftFunctionId =
      Platform.environment['GIFT_WEBHOOK_FUNCTION_ID'] ?? '68ceb9a3003b582c9099';
  try {
    // That function's execute permission is "any", so no key is needed.
    final guest = Client()
        .setEndpoint(Platform.environment['APPWRITE_FUNCTION_API_ENDPOINT'] ??
            'https://backend.ah-mar.app/v1')
        .setProject(Platform.environment['APPWRITE_FUNCTION_PROJECT_ID'] ??
            '6966d5030009343737c1');
    final execution = await Functions(guest).createExecution(
      functionId: giftFunctionId,
      body: context.req.bodyRaw,
      xasync: false,
      path: '/',
      method: ExecutionMethod.pOST,
      headers: {'signature': signature, 'content-type': 'application/json'},
    );
    final reply = execution.responseBody.trim();
    context.log('Gift $giftId forwarded: ${execution.responseStatusCode} $reply');
    return context.res.text(reply == 'SUCCESS' ? 'SUCCESS' : 'FAILURE');
  } catch (e) {
    context.error('Could not forward gift $giftId: $e');
    return context.res.text('FAILURE');
  }
}

// ══════════════════════════════════════════════════════════
// PADDLE (POST from Paddle Billing, store card payments)
// ══════════════════════════════════════════════════════════

/// Settles a completed Paddle transaction created by store-checkout.
///
/// Authenticity: the `Paddle-Signature` header is `ts=<unix>;h1=<hex>`, an
/// HMAC-SHA256 of `<ts>:<raw body>` under the notification destination's
/// secret. Only store-checkout (holding the API key) creates these
/// transactions and sets their price, so a valid signature on a completed
/// transaction is the whole check.
Future<dynamic> _handlePaddle(final context) async {
  final secret = Platform.environment['PADDLE_WEBHOOK_SECRET'] ?? '';
  final header = context.req.headers['paddle-signature'].toString();
  final raw = context.req.bodyRaw.toString();
  if (secret.isEmpty) {
    context.error('PADDLE_WEBHOOK_SECRET is not set');
    return context.res.text('FAILURE', 500);
  }

  String ts = '';
  final h1s = <String>[];
  for (final part in header.split(';')) {
    final kv = part.split('=');
    if (kv.length != 2) continue;
    if (kv[0] == 'ts') ts = kv[1];
    if (kv[0] == 'h1') h1s.add(kv[1]);
  }
  final expected =
      Hmac(sha256, utf8.encode(secret)).convert(utf8.encode('$ts:$raw')).toString();
  final age = DateTime.now().millisecondsSinceEpoch ~/ 1000 - (int.tryParse(ts) ?? 0);
  if (!h1s.contains(expected) || age.abs() > 3600) {
    context.error('Paddle: invalid signature (age ${age}s)');
    return context.res.text('INVALID SIGNATURE', 401);
  }

  final body = jsonDecode(raw) as Map<String, dynamic>;
  final type = body['event_type']?.toString() ?? '';
  if (type != 'transaction.completed') {
    context.log('Paddle: ignoring $type');
    return context.res.text('OK');
  }

  final data = body['data'] as Map<String, dynamic>;
  final custom = (data['custom_data'] as Map?)?.cast<String, dynamic>() ?? {};
  final userId = custom['user_id']?.toString() ?? '';
  final bookIds = List<String>.from(custom['book_id'] ?? const []);
  final txnId = data['id']?.toString() ?? '';
  if (userId.isEmpty || bookIds.isEmpty || custom['source'] != 'store') {
    context.error('Paddle $txnId: not a store transaction ($custom)');
    return context.res.text('OK');
  }

  final client = Client()
      .setEndpoint(Platform.environment['APPWRITE_FUNCTION_API_ENDPOINT'] ??
          'https://backend.ah-mar.app/v1')
      .setProject(Platform.environment['APPWRITE_FUNCTION_PROJECT_ID'] ??
          '6966d5030009343737c1')
      .setKey(Platform.environment['APPWRITE_API_KEY'] ?? '');
  final databases = Databases(client);
  final dbId = Platform.environment['DB_ID'] ?? '68b4bcf9001027235773';
  final libraryTable =
      Platform.environment['DB_USER_LIBRARY'] ?? 'user_library_table';
  final transactionsTable =
      Platform.environment['DB_TRANSACTIONS'] ?? 'transactions_table';

  // The receipt, once per Paddle transaction. total_price is kept in dinars
  // like every other row, so sales figures stay in one currency.
  try {
    var dzd = 0;
    for (final id in bookIds.toSet()) {
      final book = await databases.getDocument(
          databaseId: dbId,
          collectionId: Platform.environment['DB_STORE_BOOKS'] ?? 'store_books_table',
          documentId: id);
      dzd += (book.data['price'] as num?)?.round() ?? 0;
    }
    await databases.createDocument(
      databaseId: dbId,
      collectionId: transactionsTable,
      // txn_<26 chars> -> pdl_<26 chars>: 30 characters, under the 36 limit.
      documentId: 'pdl_${txnId.toLowerCase().replaceFirst('txn_', '').replaceAll(RegExp(r'[^a-z0-9]'), '')}',
      data: {
        'user_id': userId,
        'book_id': bookIds,
        'total_price': dzd,
        'status': 'completed',
      },
    );
  } on AppwriteException catch (e) {
    if (e.code == 409) {
      context.log('Paddle $txnId already recorded; repeat delivery');
    } else {
      context.error('Paddle $txnId: transaction record failed: $e');
    }
  } catch (e) {
    context.error('Paddle $txnId: transaction record failed: $e');
  }

  try {
    final found = await databases.listDocuments(
      databaseId: dbId,
      collectionId: libraryTable,
      queries: [
        Query.equal('user_id', userId),
        Query.limit(1),
        Query.select(['\$id', 'books.\$id']),
      ],
    );
    final docId =
        found.documents.isNotEmpty ? found.documents.first.$id : userId;
    final owned = <String>[];
    if (found.documents.isNotEmpty) {
      for (final item in (found.documents.first.data['books'] as List? ?? const [])) {
        if (item is Map && item['\$id'] != null) owned.add(item['\$id'].toString());
        if (item is String) owned.add(item);
      }
    }
    final updated = {...owned, ...bookIds}.toList();
    await databases.updateDocument(
      databaseId: dbId,
      collectionId: libraryTable,
      documentId: docId,
      data: {'books': updated},
    );
    context.log('Paddle $txnId: library of $userId now ${updated.length} books');
    return context.res.text('OK');
  } catch (e) {
    // Non-2xx makes Paddle retry, which is what a missed grant needs.
    context.error('Paddle $txnId: library update failed: $e');
    return context.res.text('FAILURE', 500);
  }
}
