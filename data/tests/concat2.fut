-- ==
-- input {
--   [[1,2],[3,4]]
--   [[5,6],[7,8]]
-- }
-- output {
--   [[1,2],[3,4],[5,6],[7,8]]
-- }
fun [][]int main([][]int a, [][]int b) =
  concat(a,b)
