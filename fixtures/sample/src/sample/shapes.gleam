pub type Person {
  Person(name: String, age: Int)
}

pub type Shape {
  Circle(radius: Float)
  Rectangle(Float, Float)
}

pub type Maybe(a) {
  Just(a)
  Nothing
}

pub fn birthday(person: Person) -> Person {
  let next = person.age + 1
  Person(..person, age: next)
}

pub fn area(shape: Shape) -> Float {
  case shape {
    Circle(radius: r) -> 3.0 *. r *. r
    Rectangle(w, h) -> w *. h
  }
}

pub fn describe(person: Person) -> String {
  let Person(name:, age:) = person
  let maybe = case age > 30 {
    True -> Just(age)
    False -> Nothing
  }
  case maybe {
    Just(_) -> name <> " is over thirty"
    Nothing -> name
  }
}
