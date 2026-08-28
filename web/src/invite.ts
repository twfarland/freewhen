// The invitation, built in the browser and downloaded from it.
//
// The server never sees this file, never learns the meeting link, and is not
// asked to email anyone. Once a slot is picked there is nothing left for it to
// do, which is why it is allowed to forget the room minutes later.
//
// The two instants come from the server already decided, in UTC, so this
// writes them out and does no arithmetic.

export function meetingUrl(hash: string): string {
  return `https://meet.jit.si/freewhen-${hash}`
}

export function invite(startsAt: number, endsAt: number, hash: string): string {
  return [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//FreeWhen//EN',
    'BEGIN:VEVENT',
    `UID:freewhen-${hash}@freewhen`,
    `DTSTAMP:${stamp(Date.now())}`,
    `DTSTART:${stamp(startsAt)}`,
    `DTEND:${stamp(endsAt)}`,
    'SUMMARY:FreeWhen meeting',
    `URL:${meetingUrl(hash)}`,
    `DESCRIPTION:Join at ${meetingUrl(hash)}`,
    'END:VEVENT',
    'END:VCALENDAR',
  ].join('\r\n')
}

export function download(filename: string, text: string): void {
  const url = URL.createObjectURL(new Blob([text], { type: 'text/calendar' }))
  const link = document.createElement('a')
  link.href = url
  link.download = filename
  link.click()
  URL.revokeObjectURL(url)
}

function stamp(at: number): string {
  return `${new Date(at).toISOString().replace(/[-:]/g, '').split('.')[0]}Z`
}
