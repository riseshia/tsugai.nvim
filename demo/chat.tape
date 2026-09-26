# Ask in the chat, then ask for a rename and run the proposed command.
Output demo/chat.gif
Set Shell bash
Set FontSize 16
Set Width 1400
Set Height 640
Set TypingSpeed 60ms
Set WaitTimeout 120s

Hide
Type "demo/start app.rb"
Enter
Sleep 1.5s
Show

Type " fa"
Sleep 700ms
Type "where is fetch_user used?"
Sleep 500ms
Enter
Wait+Screen /users\.rb:7/
Sleep 4s
Type " fa"
Sleep 700ms
Type "rename it to load_user everywhere"
Sleep 500ms
Enter
Wait+Screen /<CR> run/
Sleep 4s
Enter
Sleep 1s
Type ":b app.rb"
Enter
Sleep 3s
