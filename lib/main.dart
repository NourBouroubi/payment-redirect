import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dart_appwrite/dart_appwrite.dart';

Future<dynamic> main(final context) async {
  final method = (context.req.method ?? 'GET').toString().toUpperCase();
  context.log('Request method: $method');

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

      final dbId = Platform.environment['DB_ID'] ?? '68b4bcf9001027235773';
      final transactionsTable =
          Platform.environment['DB_TRANSACTIONS'] ?? 'transactions_table';
      final userLibraryTable =
          Platform.environment['DB_USER_LIBRARY'] ?? 'user_library_table';

      // --- Create Transaction Record ---
      try {
        await databases.createDocument(
          databaseId: dbId,
          collectionId: transactionsTable,
          documentId: ID.unique(),
          data: {
            'user_id': userId,
            'book_id': bookIds,
            'total_price': amount,
            'status': 'completed',
          },
        );
        context.log('Transaction record created');
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
