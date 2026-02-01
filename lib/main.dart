import 'dart:async';

Future<dynamic> main(final context) async {
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
