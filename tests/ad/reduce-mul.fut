-- Simple reduce with multiplication
-- ==
-- compiled input { [1.0f32, 2.0f32, 3.0f32, 4.0f32] 1.0f32 } output { [24.0f32, 12.0f32, 8.0f32, 6.0f32] 24.0f32 }
-- compiled input { [0.0f32, 2.0f32, 3.0f32, 4.0f32] 1.0f32 } output { [24.0f32,  0.0f32, 0.0f32, 0.0f32] 0.0f32 }

let red_mult [n] (xs: [n]f32, c: f32) : f32 =
  reduce (*) 1 xs * c

entry main [n] (xs: [n]f32) (c: f32) =
  vjp red_mult (xs,c) 1
