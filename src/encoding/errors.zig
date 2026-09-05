pub const EncodingError = error{
    CharacterCannotBeConvertedToU3,
    U3CannotBeConvertedToCharacter,
};
