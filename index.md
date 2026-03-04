Last Updated: @DATE@

@TOC@

# <var $index.project>

<foreach $index.components>
# <var $key>
| Project Name | README | Last Commit | URL |
| ------------ | ------ | ----------- | --- |
<foreach $value.pages ->
| <var $key> | <if --ref $_>[<var $_.name>](<var $_.link>)<else>[<var $_>](<var $_>)</if> | | `<var $value.url>` |
</foreach->
</foreach->
