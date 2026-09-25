# Edit a selection, revise the proposal, accept it.
Output demo/edit.gif
Set Shell bash
Set FontSize 18
Set Width 1200
Set Height 520
Set TypingSpeed 60ms
Set WaitTimeout 120s

Hide
Type "cd demo/project && nvim --clean -n -u ../init.lua users.rb"
Enter
Sleep 1.5s
Show

Type "7GV"
Sleep 700ms
Type " fe"
Sleep 700ms
Type "use each_with_object"
Sleep 500ms
Enter
Wait+Screen /accept · /
Sleep 3s
Type " fr"
Sleep 700ms
Type "name the accumulator list"
Sleep 500ms
Enter
Wait+Screen /\|id, list\|/
Sleep 3s
Type " fy"
Sleep 3s
