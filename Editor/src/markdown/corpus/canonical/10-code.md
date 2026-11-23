```ts
const a: number = 1 // keep   spacing
function f<T>(x: T): T { return x }
```

```
no language here
  indented line
	tab indented line
```

```js title="example.js" {1,3}
console.log('info string after the language is kept')
```

````md
A block that contains a fence:

```js
nested()
```
````

```text
Markdown inside code stays literal: **bold** _italic_ [link](x) <kbd> &amp; \*

# not a heading
- not a list
| not | a | table |

trailing spaces stay   
```

```python

def blank_lines_around():

    return None

```

```
```

~~~a`b
a tilde fence is kept when the info string has a backtick
~~~
