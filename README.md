# 4d-plugin-font-name
Convert between font name and display name

### Platform

| carbon | cocoa | win32 | win64 |
|:------:|:-----:|:---------:|:---------:|
|<img src="https://cloud.githubusercontent.com/assets/1725068/22371562/1b091f0a-e4db-11e6-8458-8653954a7cce.png" width="24" height="24" />|<img src="https://cloud.githubusercontent.com/assets/1725068/22371562/1b091f0a-e4db-11e6-8458-8653954a7cce.png" width="24" height="24" />|<img src="https://cloud.githubusercontent.com/assets/1725068/22371562/1b091f0a-e4db-11e6-8458-8653954a7cce.png" width="24" height="24" />|<img src="https://cloud.githubusercontent.com/assets/1725068/22371562/1b091f0a-e4db-11e6-8458-8653954a7cce.png" width="24" height="24" />|

### Version

<img src="https://cloud.githubusercontent.com/assets/1725068/18940649/21945000-8645-11e6-86ed-4a0f800e5a73.png" width="32" height="32" /> <img src="https://cloud.githubusercontent.com/assets/1725068/18940648/2192ddba-8645-11e6-864d-6d5692d55717.png" width="32" height="32" />

## Syntax

```
dst:=FONT Convert name (src;option)
```

Parameter|Type|Description
------------|------------|----
src|TEXT|Name
dst|TEXT|Name
option|LONGINT|``To display name`` or ``From display name``

## Examples

```
$name1a:=FONT Convert name ("AquaKana";To display name)
  //.Aqua かな

$name1b:=FONT Convert name ($name1a;From display name)
  //AquaKana

$name1a:=FONT Convert name (".SFNSDisplay-Regular";To display name)
  //システムフォント レギュラー

$name1b:=FONT Convert name ($name1a;From display name)
  //.SFNSDisplay-Regular

$name1a:=FONT Convert name ("Meiryo Bold Italic";To display name)
  //メイリオ ボールド イタリック

$name1b:=FONT Convert name ($name1a;From display name)
  //Meiryo-BoldItalic
```
