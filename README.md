# farmbridge

An offline synchronization design for farm visits, crop observations, and photos
over unreliable rural connectivity.

## Documentation

- [Part 1: Design decisions](DECISIONS.md)
- [Part 2: Development log](docs/part-2-development-log.md)
- [Part 3: Contractor code review](REVIEW.md)

## Setup

Requires Dart 3.4 or later.

```sh
dart pub get
dart analyze
dart test
```

The package uses `test` for behavioral tests and strict analyzer settings.
The queue implementation is in `lib/outbox_queue.dart`; behavioral tests are in
`test/outbox_queue_test.dart`. The supplied review source has an explanatory header; its code is unchanged
in `review_source/sync_service_for_review.dart`.
