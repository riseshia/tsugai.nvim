# Ask for a change across files, accept the plan, and look at what Claude changed.
Output demo/plan.gif
Set Shell bash
Set FontSize 16
Set Width 1400
Set Height 720
Set TypingSpeed 60ms
Set WaitTimeout 180s

Hide
Type "demo/start app.rb"
Enter
Sleep 1.5s
Show

Type " fa"
Sleep 700ms
Type "make the id of fetch_user a required keyword argument and update every caller"
Sleep 500ms
Enter
Wait+Screen /carry it out/
Sleep 5s
Enter
Wait+Screen /changed, listed/
Sleep 3s
Type ":!git diff --no-color"
Enter
Sleep 6s
