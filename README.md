["Build Your Own HTTP server" Challenge](https://app.codecrafters.io/courses/http-server/overview)

# Usage
```bash

# Run server
$> ./your_server.sh --directory <dir>

$> curl -X GET 'http://localhost:4221/user-agent'
```

- `GET /echo/<str>` returns `<str>` as body
- `GET /user-agent` returns user agent specified in header as body
- `GET /file/<filename>` returns content of `<filename>` as body
- `POST /file/<filename> <content>` creates a file named `<filename>` with and fills it with `<content>`

Supports gzip compression.


# TODO

- Check for memory leaks
