# Event tags

Put a tag in an event's notes or title to tell Calopod what to do with it.

| Tag | What it does |
| --- | --- |
| `#dontclone` | The event is not copied. It counts on an Arm that has the filter on (Skip events tagged #dontclone, or `--skip-dontclone`). A copy Calopod already made is removed on the next sync. |
| `#justbusy` | The event is copied as plain Busy, even by a Full details Arm, with no title, location or notes. Busy and Label Arms already copy no words, so it changes nothing there. It works on every Arm without a setting. |

A tag is read in any case, and only as a whole word, so `#DontClone` counts and `#dontcloned` does not. Calopod looks in the notes first and uses the title only when the notes have no tag. If an event has both tags, `#dontclone` wins on an Arm that skips it.

The tag is only read, never copied. A `#justbusy` copy does not carry it, and removing the tag from the original brings the details back on the next sync.

The sync preview names the tag when it is the reason an event is left out or copied as Busy. Other calendar tools ignore these tags.
